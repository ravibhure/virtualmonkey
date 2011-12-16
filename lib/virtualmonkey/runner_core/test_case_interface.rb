require 'irb'
require 'ruby-debug'

module VirtualMonkey
  # Class Variables meant to be globally accessible, used for stack tracing
  def self.trace_log=(obj)
    @@trace_log = obj
  end

  def self.trace_log
    @@trace_log ||= []
  end

  module TestCaseInterface
    attr_reader :done_resuming

    class Retry < Exception
    end

    class UnhandledException < Exception
      attr_reader :exception
      def initialize(e); @exception = e; end
      def inspect; @exception.inspect; end
      def message; @exception.message; end
      def backtrace; @exception.backtrace; end
      def to_s; @exception.to_s; end
      def set_backtrace(*args, &block)
        @exception.set_backtrace(*args, &block)
      end
      def method_missing(m, *args, &block)
        @exception.__send__(m, *args, &block)
      end
    end

    alias_method :orig_raise, :raise

    # Overrides puts to provide slightly better logging
    def puts(*args)
      write_readable_log("#{args}")
    end

    def warn(*args)
      write_readable_log("#{args}".apply_color(:uncolorize, :yellow), STDERR)
    end

    def sleep(time)
      write_readable_log("sleep(#{time})")
      super(time) if @done_resuming
    end

    # Overrides raise to provide deep debugging abilities
    def raise(*args)
      begin
        orig_raise(*args)
      rescue Exception => e
        if not self.__send__(:__exception_handle__, e)
          if ENV['MONKEY_NO_DEBUG'] != "true" && ENV['ENTRY_COMMAND'] == "grinder" && !Debugger.started? && tty?
            warn "Got exception: #{e.message}" if e
            warn "Backtrace: #{e.backtrace.join("\n")}" if e
            warn "Pausing for inspection before continuing to raise #{e.class}..."
#           if block
#              f, l = block.to_s.match(/@.*>/)[0].chop.reverse.chop.reverse.split(":")
#              puts "(Note: There is a block provided from \"#{f}\" at line #{l} that will attempt to handle the exception)"
#           end
            debugger
          end
          orig_raise(VirtualMonkey::TestCaseInterface::UnhandledException.new(e))
        else
          orig_raise(VirtualMonkey::TestCaseInterface::Retry.new)
        end
      end
    end

    # Gets called from runner_mixins/deployment_base.rb: initialize(...)
    def test_case_interface_init(options = {})
      @log_checklists = {"whitelist" => [], "blacklist" => [], "needlist" => []}
      @rerun_last_command = []

      # Trace-related Variables
      # @stack_objects is an array of referenced arrays in the current call stack
      @stack_objects = []
      # @iterating_stack is the current scope of same-depth calls to which hashes of strings mapped to arrays are appended
      @iterating_stack = []
      # @index_stack is the array indices for each of the objects currently found in @stack_objects
      @index_stack = []
      # @expected_stack_depths tracks the resume stack
      @expected_stack_depths = []
      # @retry_loop is the stack of the number of retries attempted in the current scope
      @retry_loop = []
      @done_resuming = true
      # @in_transaction tracks how deeply nested the current transaction is
      @in_transaction = []

      @all_trace_variables = [
        "@stack_objects",
        "@iterating_stack",
        "@index_stack",
        "@expected_stack_depths",
        "@retry_loop",
        "@done_resuming",
        "@in_transaction",
        "@rerun_last_command"
      ]

      @max_retries = ::VirtualMonkey::config[:max_retries]
      @options = options
      @options[:additional_logs] ||= []
      @deprecation_error = `curl -s "www.kdegraaf.net/cgi-bin/bofh" | grep -o "<b>.*</b>"`
      @deprecation_error.gsub!(/<\/*b>/,"")
      @deprecation_error.chomp!
      if @options[:resume_file] && File.exists?(@options[:resume_file])
        @done_resuming = false
      end

      # Setup runner_options
      # PUT THIS IN FEATURE FILE:
      # set "my_var", [1,2,3]
      # set :runner_options, "my-other-var" => "hello world"
      #
      # TO USE THIS IN RUNNER CLASS:
      # my_var.each { |i| print i }
      # my_other_var += " foobar"
      if @options[:runner_options] && @options[:runner_options].is_a?(Hash)
        @options[:runner_options].keys.each { |opt|
          sym = opt.gsub(/-/,"_").to_sym
          self.class.class_eval("attr_accessor :#{sym}")
          self.__send__("#{sym}=".to_sym, @options[:runner_options][opt])
        }
      end

      # Set-up relative logs in case we're being run in parallel
      # TODO: Additional logs should include each server's logs from the lists
      # PUT THIS IN FEATURE FILE:
      # set :logs, "my_special_report.html"
      #
      # TO USE THIS IN RUNNER CLASS:
      # File.open(@log_map["my_special_report.html"], "w") { |f| f.write("blah") }
      @log_map = @options[:additional_logs].map_to_h { |log|
        file_name = "#{@deployment.nickname}.#{File.basename(log)}"
        base_dir = ENV['MONKEY_LOG_BASE_DIR'] || File.dirname(log)
        File.join(base_dir, file_name)
      }

      ::VirtualMonkey::trace_log << { "feature_file" => @options[:file] }
      write_readable_log("feature_file: #{@options[:file]}")
      # Do renaming stuff
      all_methods = self.methods + self.private_methods -
                    Object.new().methods - Object.new().private_methods -
                    VirtualMonkey::TestCaseInterface.instance_methods -
                    VirtualMonkey::TestCaseInterface.private_instance_methods
      behavior_methods = all_methods.select { |m| m !~ /(exception_handle)|(^__.*__$)|(resource_id)|(^__behavior)/i }
      # SKIP this if we've already done the alias_method dance
      return if self.respond_to?("__behavior_#{behavior_methods.first}".to_sym)

      behavior_methods.each do |m|
        new_m = "__behavior_#{m}"
        self.class.class_eval("alias_method :#{new_m}, :#{m}; def #{m}(*args, &block); function_wrapper(:#{m},:#{new_m}, *args, &block); end")
      end
    end

    def function_wrapper(sym, behave_sym, *args, &block)
      timing = Time.now
      if sym.to_s =~ /^set/
        call_str = stringify_call(sym, args) unless block
        call_str = stringify_call(sym, args, nil, block.to_ruby) if block
        write_readable_log(call_str)
        ret = __send__(behave_sym, *args, &block)
        write_readable_log("Duration: #{Time.duration(Time.now - timing, :include_usec)}")
        return ret
      end

      @retry_loop << 0
      execution_stack_trace(sym, args) unless block
      execution_stack_trace(sym, args, nil, block.to_ruby) if block
      begin
        push_rerun_test
        #pre-command
        populate_settings if @deployment
        done_resuming?
        #command
        result = __send__(behave_sym, *args, &block)
        #post-command
        continue_test
      rescue VirtualMonkey::TestCaseInterface::Retry
      end while @rerun_last_command.pop
      write_trace_log
      write_readable_log("Duration: #{Time.duration(Time.now - timing, :include_usec)}")
      @retry_loop.pop
      result
    end

    # verify is meant to wrap every function call to provide the following functionality:
    # * Execution Tracing
    # * Exception Handling
    # * Runner-Contextual Debugging
    # * Built-in retrying
=begin
    def verify(sym, *args, &block)
      @retry_loop << 0
      execution_stack_trace(sym, args)
      begin
        push_rerun_test
        #pre-command
        populate_settings if @deployment
        #command
        result = __send__(sym, *args)
        if block
          raise "FATAL: Failed behavior verification. Result was:\n#{result.inspect}" if not yield(result)
        end
        #post-command
        continue_test
      rescue Exception => e
        if block and e.message !~ /^FATAL: Failed behavior verification/
          raise if not yield(e)
        else
          raise
        end
      end while @rerun_last_command.pop
      clean_stack_trace
      @retry_loop.pop
      result
    end
=end

    # Launches an irb debugging session if
    def launch_irb_session(debug = false)
      IRB.start unless debug
      debugger if debug
    end

    # transaction doesn't quite live up to its namesake. It only implies all-or-nothing resume capabilities,
    # rather than all-or-nothing execution.
    def transaction(option = nil, &block)
      # TODO: Manage threaded execution across the elements of the ordered_ary. Remember to shift from a
      # duplicated ary rather than passing in args.
      #
      # threads = []
      # audits.each { |audit| threads << Thread.new(audit) { |a| a.wait_for_completed } }
      # threads.each { |t| t.join }
      #
      timing = Time.now
      call_str = stringify_call("transaction", [], nil, block.to_ruby)
      write_readable_log(call_str) unless option == :do_not_trace
      real_trace_log = nil
      if @in_transaction.empty?
        real_stack_objects, @stack_objects = @stack_objects, []
        real_iterating_stack, @iterating_stack = @iterating_stack, []
        real_trace_log, ::VirtualMonkey::trace_log = ::VirtualMonkey::trace_log, []
      end

      result = nil
      begin
        @in_transaction.push(true)
        populate_settings if @deployment
        done_resuming?(real_trace_log)

        # Retry loop
        begin
          push_rerun_test
          result = yield() if @done_resuming
          continue_test
        rescue VirtualMonkey::TestCaseInterface::Retry
        rescue VirtualMonkey::TestCaseInterface::UnhandledException => e
          begin
            orig_raise e.exception
          rescue Exception => e
            orig_raise
          end
        rescue Exception => e
          begin
            raise e # Need to use the internal raise
          rescue VirtualMonkey::TestCaseInterface::Retry
          rescue VirtualMonkey::TestCaseInterface::UnhandledException => e
            begin
              orig_raise e.exception
            rescue Exception => e
              orig_raise
            end
          end
        end while @rerun_last_command.pop

      ensure
        @in_transaction.pop
        if @in_transaction.empty?
          # Return class and instance variables to normal
          @iterating_stack = real_iterating_stack
          @stack_objects = real_stack_objects
          ::VirtualMonkey::trace_log = real_trace_log
        end
      end
      write_trace_log(call_str) unless option == :do_not_trace
      write_readable_log(Time.duration(Time.now - timing), :include_usec)
      result
    end

    def write_readable_log(data, io=STDOUT)
      data_ary = data.split("\n")
      data_ary.each_index do |i|
        data_ary[i] = ("  " * (@rerun_last_command || []).length) + data_ary[i]
      end
      io.puts "#{data_ary.join("\n")}"
    end

    def write_trace_log(call=nil)
      return nil unless @in_transaction.empty?
      add_to_trace_log(call) if call.is_a?(String)
      if @done_resuming and @options[:resume_file]
        File.open(@options[:resume_file], "w") { |f| f.write( ::VirtualMonkey::trace_log.to_yaml ) }
      end
    end

    def match_servers_by_st(ref)
      @st_table.select { |s,st| st.href == ref.href }.map { |s,st| s }
    end

    def match_st_by_server(ref)
      @st_table.select { |s,st| s.href == ref.href }.last.last
    end

    private

    def obj_behavior(obj, sym, *args)
      warn "#{@deprecation_error.upcase} occured!  You are using a deprecated method called 'obj_behavior'"
      transaction { obj.__send__(sym, *args) }
    end

    # Master exception_handle method. Calls all other exception handlers
    def __exception_handle__(e)
      all_methods = self.methods + self.private_methods
      exception_handle_methods = all_methods.select { |m| m =~ /exception_handle/ and m !~ /^__/ }

      @retry_loop ||= []
      return false if @retry_loop.empty? or @retry_loop.last >= @max_retries
      exception_handle_methods.each { |m|
        if self.__send__(m,e)
          # If an exception_handle method doesn't return false, it handled correctly
          incr_retry_loop
          return true # Exception Handled
        end
      }
      # Exception wasn't handled
      return false
    end

    # Master list_loader method. Calls all other list load methods
    def __list_loader__
      all_methods = self.methods + self.private_methods
      MessageCheck::LISTS.each do |list|
        list_methods = all_methods.select { |m| m =~ /#{list}/ and m !~ /^__/ }
        list_methods.each do |m|
          result = self.__send__(m)
          @log_checklists[list] += result if result.is_a?(Array)
        end
      end
    end

    # debugger irb help function
    def help
      puts <<EOS
Here are some of the wrapper methods that may be of use to you in your debugging quest:

probe(server_set, shell_command, &block): Provides a one-line interface for running a command on
                                          a set of servers and verifying their output. The block
                                          should take one argument, the output string from one of
                                          the servers, and return true or false based on however
                                          the developer wants to verify correctness.

                                          Examples:
                                            probe('.*', 'ls') { |s| puts s }
                                            probe(:fe_servers, 'ls') { |s| puts s }
                                            probe('app_servers', 'ls') { |s| puts s }
                                            probe('.*', 'uname -a') { |s| s =~ /x64/ }

continue_test: Disables the retry loop that reruns the last command (the current command that you're
               debugging.

help: Prints this help message.
EOS
    end

    # Sets up most of the state for the runners
    def populate_settings
      @populated ||= false
      unless @populated
        @populated = true
        @servers = @deployment.servers_no_reload
        @servers.reject! { |s|
          s.settings
          st = ServerTemplate.find(resource_id(s.server_template_href))
          if @options[:allow_meta_monkey]
            ret = false
          else
            ret = (st.nickname =~ /virtual *monkey/i)
          end
          @server_templates << st unless ret
          @st_table << [s, st] unless ret
          ret
        }
        @server_templates.uniq!
        self.__send__(:__lookup_scripts__)
        self.__send__(:__list_loader__)
      end
    end

    # select_set returns an Array of ServerInterfaces and accepts any of the following:
    # * <~Array> will return the Array
    # * <~String> will first attempt to find a function in the runner with that String to get
    # *           an Array/ServerInterface (e.g. app_servers, s_one). If that fails, then it
    # *           will use the String as a regex to select a subset of servers.
    # * <~Symbol> will attempt to run a function in the runner to get an Array/ServerInterface
    # *           (e.g. app_servers, s_one)
    # * <~ServerInterface> will return a one-element Array with the ServerInterface
    def select_set(set = @servers)
      passed_param = set
      if set.is_a?(String)
        if self.respond_to?(set.to_sym)
          set = set.to_sym
        else
          set = @servers.select { |s| s.nickname =~ /#{set}/ }
        end
      end
      if set.is_a?(Regexp)
        set = match_servers_by_st(@server_templates.detect { |st| st.name =~ set || st.nickname =~ set })
      end
      set = match_servers_by_st(set) if set.is_a?(ServerTemplate)
      set = __send__(set) if set.is_a?(Symbol)
      set = [ set ] unless set.is_a?(Array)
      raise "FATAL: No servers found for passed #{passed_param.class}: #{passed_param.inspect}" if set.empty?
      return set
    end

    # Encapsulates the logic necessary for retrying a function
    def push_rerun_test
      @rerun_last_command.push(true)
    end

    # Encapsulates the logic necessary for continuing after function
    def continue_test
      @rerun_last_command.pop
      @rerun_last_command.push(false)
    end

    # allows exceptions to only handle a limited number of times per behavior
    def incr_retry_loop
      @retry_loop.map! { |i| i + 1 }
    end

    def timestamp
      t = Time.now
      "#{t.strftime("[%m/%d/%Y %H:%M:%S.")}%-6d] " % t.usec
    end

=begin
    def method_missing(sym, *args, &block)
      str = sym.to_s
      assignment = str.gsub!(/=/,"")
      str_dash = str.gsub(/_/,"-")
      if @options[:runner_options][str]
        @options[:runner_options][str] = args.first if assignment
        return @options[:runner_options][str]
      elsif @options[:runner_options][str_dash]
        @options[:runner_options][str_dash] = args.first if assignment
        return @options[:runner_options][str_dash]
      else
        raise NoMethodError.new("undefined method '#{sym}' for #{self.class}")
      end
    end
=end

    ##################################
    # Execution Stack Trace Routines #
    ##################################

    # Execution Stack Trace function
    def execution_stack_trace(sym, args, obj=nil, block_text="")
      call = stringify_call(sym, args, obj, block_text)
      write_readable_log(call)

      add_to_trace_log(call)
    end

    def add_to_trace_log(call)
      return nil unless ::VirtualMonkey::trace_log

      referenced_ary = []
      add_hash = { call => referenced_ary }
      # Add string to proper place
      if @rerun_last_command.length < @stack_objects.length # shallower or same level call
        diff = Math.abs(@stack_objects.length - @rerun_last_command.length)
        unless @done_resuming
          begin
            # Check Length & Depth Expectations
            if @stack_objects.length < @expected_stack_depths.length
              msg = "Expected Stack Depth not met, cancelling resume."
              warn "#{__FILE__}::#{__LINE__}: #{msg}"
              inspect_trace_objects
              @done_resuming = true
            end
            if @iterating_stack.length < @expected_stack_depths.last
              msg = "Expected number of sub-function calls not met, cancelling resume."
              warn "#{__FILE__}::#{__LINE__}: #{msg}"
              inspect_trace_objects
              @done_resuming = true
            end
          rescue Exception => e
            warn "RESUME EXCEPTION: Got \"#{e}\". Cancelling resume and continuing"
            inspect_trace_objects
            warn "Exception Backtrace:\n#{e.backtrace.join("\n")}"
            @done_resuming = true
          end
        end
        @stack_objects.pop(diff)
        @index_stack.pop(diff)
        @expected_stack_depths.pop(diff)
      end
      unless @done_resuming
        begin
          # Check Depth Expectations
          if @stack_objects.length < @expected_stack_depths.length
            msg = "Expected Stack Depth not met, cancelling resume."
            warn "#{__FILE__}::#{__LINE__}: #{msg}"
            inspect_trace_objects
            @done_resuming = true
          end
        rescue Exception => e
          warn "RESUME EXCEPTION: Got \"#{e}\". Cancelling resume and continuing"
          inspect_trace_objects
          warn "Exception Backtrace:\n#{e.backtrace.join("\n")}"
          @done_resuming = true
        end
      end
      if @stack_objects.empty?
        @index_stack << ::VirtualMonkey::trace_log.length
        ::VirtualMonkey::trace_log << add_hash
      else
        @iterating_stack = @stack_objects.last # get the last object from the object stack
        @iterating_stack << add_hash # here were are adding to iterating stack
        @index_stack[-1] += 1
        @index_stack << 0
      end
      @stack_objects << referenced_ary
    end

    def stringify_call(sym, args, obj=nil, block_text="")
      arg_ary = args.map { |item| stringify_arg(item) }
      call = sym.to_s
      call += "(#{arg_ary.join(", ")})" unless args.empty?
      call = stringify_arg(obj) + "." + call if obj
      call += block_text.gsub(/proc /, " ") if block_text != ""
      return call
    end

    def done_resuming?(real_trace_log = nil)
      resume_stack_objects = nil
      begin
        return true if @done_resuming
        return false unless @in_transaction.empty? # Can only resume from OUTSIDE a transaction
        # Rebuild Stack from Resume Log
        # Build Stack Length and Depth Expectations Simultaneously
        resume_log = YAML::load(IO.read(@options[:resume_file]))
        if ::VirtualMonkey::trace_log == []
          if real_trace_log == resume_log
            return @done_resuming = true
          end
        elsif ::VirtualMonkey::trace_log == resume_log
          return @done_resuming = true
        end

        if ::VirtualMonkey::trace_log[0] != resume_log[0]
          # The runner is still being instantiated if these two aren't equal.
          return false
        end
        resume_stack_objects = []
        @expected_stack_depths = []

        build_resume_stack = proc do |key,ary|
          resume_stack_objects << ary
          if ary.first
            @expected_stack_depths << ary.length
            new_key = ary.first.first.first
            new_ary = ary.first.first.last
            build_resume_stack.call(new_key, new_ary)
          end
        end

        next_key, next_ary = nil, nil
        @index_stack.each_with_index { |stack_index,i|
          if next_ary
            if next_ary.length < stack_index
              # TODO STATE CHECK: Have we finished resuming?
              # Number of functions called from previous run in this scope is less than number of functions called in current run
              # Check that they're at the end of the resume stack
              msg = "Number of functions called from previous run in this scope is less than number of functions called in current run"
              warn "#{__FILE__}::#{__LINE__}: #{msg}"
              inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
              return @done_resuming = true
            else
              @expected_stack_depths << next_ary.length
            end
            next_key = next_ary[stack_index].first.first
            next_ary = next_ary[stack_index].first.last
          else
            if resume_log.length < stack_index
              # TODO STATE CHECK: Have we finished resuming?
              # Number of functions called from previous run in this scope is less than number of functions called in current run
              # Check that they're at the end of the resume stack
              msg = "Number of functions called from previous run in this scope is less than number of functions called in current run"
              warn "#{__FILE__}::#{__LINE__}: #{msg}"
              inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
              return @done_resuming = true
            else
              @expected_stack_depths << resume_log.length
            end
            next_key = resume_log[stack_index].first.first
            next_ary = resume_log[stack_index].first.last
          end
          resume_stack_objects << next_ary
        }
        unless resume_stack_objects.last.empty?
          next_key = resume_stack_objects.last.first.first.first
          next_ary = resume_stack_objects.last.first.first.last
          build_resume_stack.call(next_key, next_ary)
        end

        # Check State Expectations
        # First, check function signature
        fn_signatures_equal = resume_stack_objects.zip(@stack_objects, Array(0...@index_stack.length)).reduce(true) { |bool,set|
          idx = (set[-1] == (@index_stack.length - 1) ? 0 : @index_stack[set[-1] + 1])
          bool && (set[0][idx].first.first == set[1][idx].first.first)
        }
        unless fn_signatures_equal
          msg = "Function Signature mismatch!"
          warn "#{__FILE__}::#{__LINE__}: #{msg}"
          inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
          return @done_resuming = true
        end

        # Next, check stack depths against expected depths
        if @index_stack.length <= @expected_stack_depths.length
          # In acceptable boundaries
          if @index_stack[-1] < @expected_stack_depths[@index_stack.length - 1]
            # In acceptable boundaries
            return @done_resuming = false
          else
            if @expected_stack_depths.length > 1
              if @index_stack[-2] < @expected_stack_depths[@index_stack.length - 2]
                msg = "Current scope has executed more lines than expected"
                warn "#{__FILE__}::#{__LINE__}: #{msg}"
                inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
                return @done_resuming = true
              else
                # Should never get here...
                msg = "Unaccounted-for anomaly while checking resume"
                warn "#{__FILE__}::#{__LINE__}: #{msg}"
                inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
                return @done_resuming = true
              end
            else
              # Should never get here...
              msg = "Unaccounted-for anomaly while checking resume"
              warn "#{__FILE__}::#{__LINE__}: #{msg}"
              inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
              return @done_resuming = true
            end
          end
        else
          # Have gone farther than the resume
          if @index_stack[@expected_stack_depths.length - 1] < @expected_stack_depths[-1]
            msg = "Current stack is deeper than expected"
            warn "#{__FILE__}::#{__LINE__}: #{msg}"
            inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
            return @done_resuming = true
          else
            # Should never get here...
            msg = "Unaccounted-for anomaly while checking resume"
            warn "#{__FILE__}::#{__LINE__}: #{msg}"
            inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
            return @done_resuming = true
          end
        end
        return false
      rescue Exception => e
        warn "RESUME EXCEPTION: Got \"#{e}\". Cancelling resume and continuing"
        inspect_trace_objects("resume_stack_objects" => resume_stack_objects)
        warn "Exception Backtrace:\n#{e.backtrace.join("\n")}"
        return @done_resuming = true
      end
    end

    def inspect_trace_objects(*args)
      # Each Argument should be a hash
      obj_hsh = @all_trace_variables.map_to_h { |var| instance_variable_get(var) }
      args.each { |hsh| obj_hsh.merge! hsh }
      obj_hsh["trace_log"] = ::VirtualMonkey::trace_log
      obj_hsh["resume_log"] = YAML::load(IO.read(@options[:resume_file]))
      obj_hsh.each { |name,val| warn "\n#{name}:\n#{val.pretty_inspect}" }
    end

    # Stringify stack_trace args
    def stringify_arg(arg, will_be_inspected = false)
      return arg.class.to_s if arg.is_a?(AuditEntry)
      return arg.inspect if arg.is_a?(Class)

      if arg.is_a?(Array)
        new_ary = arg.map { |item| stringify_arg(item, true) }
        return (will_be_inspected ? new_ary : new_ary.trace_inspect)
      end

      if arg.is_a?(Hash)
        new_hsh = {}
        arg.each { |k,v| new_hsh[ stringify_arg(k, true) ] = stringify_arg(v, true) }
        return (will_be_inspected ? new_hsh : new_hsh.trace_inspect)
      end

      return (will_be_inspected ? arg : arg.trace_inspect) if arg.respond_to?(:trace_inspect)
      return arg.class.to_s
    end
  end
end

class TransactionSet
end
