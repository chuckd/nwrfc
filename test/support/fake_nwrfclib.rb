require 'ffi'

class String
  def cU
    self
  end unless method_defined?(:cU)
end

module NWRFCLib
  class Enum
    def initialize(values)
      @values = values
      @names = values.invert
    end

    def [](value)
      value.kind_of?(Symbol) ? @values[value] : @names[value]
    end
  end

  RFC_RC = Enum.new(
    :RFC_OK => 0,
    :RFC_ABAP_EXCEPTION => 5,
    :RFC_EXTERNAL_FAILURE => 15
  )
  RFC_ERROR_GROUP = Enum.new(:EXTERNAL_RUNTIME_FAILURE => 5)

  class ErrorText
    def initialize(value = '')
      @value = value
    end

    def get_str
      @value
    end
  end

  class RFCError
    def initialize(*)
      @values = {
        :code => 0,
        :group => 0,
        :key => ErrorText.new,
        :message => ErrorText.new,
        :abapMsgType => ErrorText.new,
        :abapMsgNumber => ErrorText.new
      }
    end

    def [](key)
      @values[key]
    end

    def []=(key, value)
      @values[key] = value
    end

    def to_ptr
      self
    end
  end
end

binding_path = File.expand_path('../../lib/nwrfc/nwrfclib', __dir__)
$LOADED_FEATURES << binding_path
$LOADED_FEATURES << "#{binding_path}.rb"
