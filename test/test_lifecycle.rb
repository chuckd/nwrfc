require 'test/unit'

if ENV['NWRFC_FAKE_LIB'] == '1' || ENV['NWRFC_REAL_LIB'] == '1'
  require File.expand_path('support/fake_nwrfclib', __dir__) if ENV['NWRFC_FAKE_LIB'] == '1'
  require File.expand_path('../lib/nwrfc', __dir__)

  class TestLifecycle < Test::Unit::TestCase
    include NWRFC

    def pointer(address)
      FFI::Pointer.new(address)
    end

    def set_error(error, code)
      error = NWRFCLib::RFCError.new(error) if error.kind_of?(FFI::Pointer)
      error[:code] = code
      error[:group] = NWRFCLib::RFC_ERROR_GROUP[:EXTERNAL_RUNTIME_FAILURE]
      nil
    end

    def with_nwrfclib_stubs(stubs)
      originals = {}
      stubs.each do |name, implementation|
        originals[name] = NWRFCLib.method(name) if NWRFCLib.respond_to?(name)
        NWRFCLib.singleton_class.send(:define_method, name) do |*args|
          implementation.call(*args)
        end
      end
      yield
    ensure
      originals.each do |name, implementation|
        if implementation
          NWRFCLib.singleton_class.send(:define_method, name, implementation)
        else
          NWRFCLib.singleton_class.send(:remove_method, name)
        end
      end
    end

    def test_owned_function_call_closes_once_and_blocks_description_destruction
      destroyed_calls = []
      destroyed_descs = []
      function_handle = pointer(1)
      desc_handle = pointer(2)
      stubs = {
        :create_function_desc => lambda { |_name, error| set_error(error, 0); desc_handle },
        :create_function => lambda { |_desc, error| set_error(error, 0); function_handle },
        :destroy_function => lambda { |handle, error| set_error(error, 0); destroyed_calls << handle; 0 },
        :destroy_function_desc => lambda { |desc, error| set_error(error, 0); destroyed_descs << desc; 0 }
      }

      with_nwrfclib_stubs(stubs) do
        function = Function.new('LOCAL')
        function_call = function.get_function_call

        assert_raise(RuntimeError) { function.close }
        function_call.close
        function_call.destroy
        assert_nil(function_call.handle)
        assert_equal([function_handle], destroyed_calls)

        function.close
        function.destroy
        assert_nil(function.desc)
        assert_equal([desc_handle], destroyed_descs)
      end
    end

    def test_borrowed_function_call_is_never_destroyed
      destroyed = []
      handle = pointer(3)
      stubs = {
        :describe_function => lambda { |_handle, error| set_error(error, 0); pointer(4) },
        :destroy_function => lambda { |function, _error| destroyed << function; 0 }
      }

      with_nwrfclib_stubs(stubs) do
        function_call = FunctionCall.new(handle)
        function_call.close
        function_call.destroy
        assert_nil(function_call.handle)
        assert_empty(destroyed)
      end
    end

    def test_function_call_retains_handle_when_destroy_fails
      attempts = 0
      handle = pointer(5)
      stubs = {
        :create_function_desc => lambda { |_name, error| set_error(error, 0); pointer(6) },
        :create_function => lambda { |_desc, error| set_error(error, 0); handle },
        :destroy_function => lambda do |_function, error|
          attempts += 1
          set_error(error, attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0)
          attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
        end,
        :destroy_function_desc => lambda { |_desc, error| set_error(error, 0); 0 }
      }

      with_nwrfclib_stubs(stubs) do
        function = Function.new('LOCAL')
        function_call = function.get_function_call
        assert_raise(NWError) { function_call.close }
        assert_equal(handle, function_call.handle)
        assert_raise(RuntimeError) { function.close }
        function_call.close
        assert_nil(function_call.handle)
        assert_equal(2, attempts)
        function.close
      end
    end

    def test_cached_function_description_is_never_destroyed
      destroyed = []
      desc_handle = pointer(7)
      connection = Struct.new(:handle).new(pointer(8))
      stubs = {
        :get_function_desc => lambda { |_connection, _name, error| set_error(error, 0); desc_handle },
        :destroy_function_desc => lambda { |desc, _error| destroyed << desc; 0 }
      }

      with_nwrfclib_stubs(stubs) do
        function = Function.new(connection, 'CACHED')
        function.close
        function.destroy
        assert_nil(function.desc)
        assert_empty(destroyed)
      end
    end

    def test_owned_function_description_retains_handle_when_destroy_fails
      attempts = 0
      desc_handle = pointer(9)
      stubs = {
        :create_function_desc => lambda { |_name, error| set_error(error, 0); desc_handle },
        :destroy_function_desc => lambda do |_desc, error|
          attempts += 1
          set_error(error, attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0)
          attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
        end
      }

      with_nwrfclib_stubs(stubs) do
        function = Function.new('LOCAL')
        assert_raise(NWError) { function.close }
        assert_equal(desc_handle, function.desc)
        function.close
        assert_nil(function.desc)
        assert_equal(2, attempts)
      end
    end

    def test_with_function_call_closes_after_block_error
      destroyed = []
      stubs = {
        :create_function_desc => lambda { |_name, error| set_error(error, 0); pointer(10) },
        :create_function => lambda { |_desc, error| set_error(error, 0); pointer(11) },
        :destroy_function => lambda { |handle, error| set_error(error, 0); destroyed << handle; 0 },
        :destroy_function_desc => lambda { |_desc, error| set_error(error, 0); 0 }
      }

      with_nwrfclib_stubs(stubs) do
        function = Function.new('LOCAL')
        assert_raise(RuntimeError) do
          function.with_function_call { raise 'block failed' }
        end
        assert_equal(1, destroyed.length)
        function.close
      end
    end

    def test_transaction_retries_only_the_failed_step_and_closes_once
      submit_attempts = 0
      confirm_attempts = 0
      destroy_attempts = 0
      stubs = {
        :submit_transaction => lambda do |_handle, error|
          submit_attempts += 1
          code = submit_attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
          set_error(error, code)
          code
        end,
        :confirm_transaction => lambda do |_handle, error|
          confirm_attempts += 1
          code = confirm_attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
          set_error(error, code)
          code
        end,
        :destroy_transaction => lambda { |_handle, error| set_error(error, 0); destroy_attempts += 1; 0 }
      }

      with_nwrfclib_stubs(stubs) do
        transaction = Transaction.new(pointer(12))
        assert_raise(NWError) { transaction.commit }
        assert_raise(NWError) { transaction.commit }
        transaction.commit
        transaction.close
        assert_nil(transaction.handle)
        assert_equal(2, submit_attempts)
        assert_equal(2, confirm_attempts)
        assert_equal(1, destroy_attempts)
      end
    end

    def test_transaction_close_retains_handle_when_destroy_fails
      attempts = 0
      handle = pointer(13)
      stubs = {
        :destroy_transaction => lambda do |_handle, error|
          attempts += 1
          code = attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
          set_error(error, code)
          code
        end
      }

      with_nwrfclib_stubs(stubs) do
        transaction = Transaction.new(handle)
        assert_raise(NWError) { transaction.close }
        assert_equal(handle, transaction.handle)
        transaction.destroy
        assert_nil(transaction.handle)
        assert_equal(2, attempts)
      end
    end

    def test_transaction_commit_retries_only_destroy_after_destroy_fails
      submit_attempts = 0
      confirm_attempts = 0
      destroy_attempts = 0
      stubs = {
        :submit_transaction => lambda { |_handle, error| set_error(error, 0); submit_attempts += 1; 0 },
        :confirm_transaction => lambda { |_handle, error| set_error(error, 0); confirm_attempts += 1; 0 },
        :destroy_transaction => lambda do |_handle, error|
          destroy_attempts += 1
          code = destroy_attempts == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
          set_error(error, code)
          code
        end
      }

      with_nwrfclib_stubs(stubs) do
        transaction = Transaction.new(pointer(18))
        assert_raise(NWError) { transaction.commit }
        transaction.commit
        assert_equal(1, submit_attempts)
        assert_equal(1, confirm_attempts)
        assert_equal(2, destroy_attempts)
        assert_nil(transaction.handle)
      end
    end

    def test_connection_and_server_close_are_idempotent
      closed = []
      stub = lambda { |handle, error| set_error(error, 0); closed << handle; 0 }

      with_nwrfclib_stubs(:close_connection => stub) do
        connection = Connection.allocate
        connection.instance_variable_set(:@handle, pointer(14))
        connection.instance_variable_set(:@error, NWRFCLib::RFCError.new)
        server = Server.allocate
        server.instance_variable_set(:@handle, pointer(15))
        server.instance_variable_set(:@error, NWRFCLib::RFCError.new)

        connection.close
        connection.disconnect
        server.close
        server.disconnect
        assert_nil(connection.handle)
        assert_equal(2, closed.length)
      end
    end

    def test_connection_and_server_retain_handles_when_close_fails
      attempts = Hash.new(0)
      stub = lambda do |handle, error|
        attempts[handle] += 1
        code = attempts[handle] == 1 ? NWRFCLib::RFC_RC[:RFC_EXTERNAL_FAILURE] : 0
        set_error(error, code)
        code
      end

      with_nwrfclib_stubs(:close_connection => stub) do
        connection = Connection.allocate
        connection.instance_variable_set(:@handle, pointer(16))
        connection.instance_variable_set(:@error, NWRFCLib::RFCError.new)
        server = Server.allocate
        server.instance_variable_set(:@handle, pointer(17))
        server.instance_variable_set(:@error, NWRFCLib::RFCError.new)

        assert_raise(NWError) { connection.close }
        assert_raise(NWError) { server.close }
        assert_not_nil(connection.handle)
        assert_not_nil(server.instance_variable_get(:@handle))
        connection.close
        server.close
        assert_nil(connection.handle)
        assert_nil(server.instance_variable_get(:@handle))
      end
    end
  end
else
  require 'rbconfig'

  class TestLifecycleBootstrap < Test::Unit::TestCase
    def test_lifecycle_with_stubbed_native_library
      env = { 'NWRFC_FAKE_LIB' => '1' }
      assert(system(env, RbConfig.ruby, __FILE__))
    end
  end
end
