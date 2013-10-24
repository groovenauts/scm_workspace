require 'fileutils'
require 'logger'

module FileUtils

  class << self
    def with_logger(logger, level = :info)
      output = LoggerAdapter.new(logger, level)

      Module.new do
        include FileUtils
        @fileutils_output  = output
        @fileutils_label   = ''

        ::FileUtils.collect_method(:verbose).each do |name|
          module_eval(<<-EOS, __FILE__, __LINE__ + 1)
            def #{name}(*args)
              super(*fu_update_option(args, :verbose => true))
            end
            private :#{name}
          EOS
        end

        extend self
        class << self
          ::FileUtils::METHODS.each do |m|
            public m
          end
        end
      end

    end
  end

  class LoggerAdapter
    def initialize(logger, level)
      @logger, @level = logger, level
    end
    def puts(msg)
      @logger.send(@level, msg)
    end
  end

end
