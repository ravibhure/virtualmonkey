module VirtualMonkey
  module RunnerCore
    module CommandHooks
      #
      # Monkey Create/Destroy API Hooks
      #

      def before_create(*args, &block)
        @@before_create ||= {}
        @@before_create[self.to_s] ||= []
        @@before_create[self.to_s] |= args
        @@before_create[self.to_s] << block if block_given?
        @@before_create[self.to_s]
      end

      def after_create(*args, &block)
        @@after_create ||= {}
        @@after_create[self.to_s] ||= []
        @@after_create[self.to_s] |= args
        @@after_create[self.to_s] << block if block_given?
        @@after_create[self.to_s]
      end

      def before_run(*args, &block)
        @@before_run ||= {}
        @@before_run[self.to_s] ||= []
        @@before_run[self.to_s] |= args
        @@before_run[self.to_s] << block if block_given?
        @@before_run[self.to_s]
      end

      def before_destroy(*args, &block)
        @@before_destroy ||= {}
        @@before_destroy[self.to_s] ||= []
        @@before_destroy[self.to_s] |= args
        @@before_destroy[self.to_s] << block if block_given?
        @@before_destroy[self.to_s]
      end

      def after_destroy(*args, &block)
        @@after_destroy ||= {}
        @@after_destroy[self.to_s] ||= []
        @@after_destroy[self.to_s] |= args
        @@after_destroy[self.to_s] << block if block_given?
        @@after_destroy[self.to_s]
      end

      def description(desc="")
        @@description ||= {}
        @@description[self.to_s] ||= desc
        raise "FATAL: Description must be a string" unless @@description[self.to_s].is_a?(String)
        @@description[self.to_s]
      end

      def assert_integrity!
        if self.description.empty?
          msg = "FATAL: Description not set for #{self}.\nRunners are required to have a "
          msg += "simple description of functionality defined in the class by specifying:\n\n"
          msg += "'description \"My Description Here\"'.\n\nYou will need to ensure that your "
          msg += "Runner class (#{self}) also extends VirtualMonkey::RunnerCore::CommandHooks using:\n\n"
          msg += "'extend VirtualMonkey::RunnerCore::CommandHooks'"
          error msg
        end
        self.before_create.each { |fn|
          if not fn.is_a?(Proc)
            raise "FATAL: #{self.to_s} does not have a class method named #{fn}; before_create requires class methods" unless self.respond_to?(fn)
          end
        }
      end
    end
  end
end
