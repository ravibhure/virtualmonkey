module VirtualMonkey
  class TestCase
    attr_accessor :options, :file_stack
    attr_reader :features
    STAGES = [:hard_reset, :soft_reset, :before, :test, :after]

    def mixin_feature(file, isolate_feature_set = false)
      project = VirtualMonkey::Manager::Collateral::get_project_from_file(file)
      file = File.join(project.paths["features"], File.basename(file))
      if @features.keys.include? file
        puts "NOTE: Feature #{file} already mixed in. Skipping."
        return @current_file
      end
      if @file_stack.include? file
        warn "WARNING: Recursive mixin detected. Skipping."
        return @current_file
      end
      @file_stack.push(file)
      @current_file = file
      @keys_per_feature[@current_file] ||= []
      ruby = IO.read(file)
      # Setting this to true will isolate the tests and call reset between feature sets
      @features[file] = isolate_feature_set
      # TODO Do actual mixins with the ability to enqueue a set of before/after stuff
      eval(ruby, binding, file, 1)
      @file_stack.pop
      @current_file = @file_stack.last
    end

    def initialize(file, options = {})
      project = VirtualMonkey::Manager::Collateral::get_project_from_file(file)
      file = File.join(project.paths["features"], File.basename(file))
      @blocks = STAGES.map_to_h { |s| {} }
      @features = {}
      @tests_to_resume, @feature_in_progress = nil, nil
      @completed_features, @features_to_run = [], []
      @options = options
      @options[:additional_logs] = []
      @options[:runner_options] = {}
      @runner = nil
      @all_keys = []
      @file_stack = [file]
      @current_file = file
      @keys_per_feature = {@current_file => []}
      @main_feature = file
      @features[file] = false
      ruby = IO.read(file)
      eval(ruby, binding, file, 1)
      raise "Need a VirtualMonkey::Runner Class!" unless @options[:runner]
      @file_stack.pop
      @current_file = @file_stack.last
      @all_keys.freeze
      @keys_per_feature.freeze
      self
    end

    def get_keys(*features)
      return @all_keys.dup if features.empty?
      features.map { |feature| @keys_per_feature[feature].dup }.flatten.compact.uniq
    end

    def check_for_resume
      # Should we resume?
      test_states = VirtualMonkey::TEST_STATE_DIR
      state_dir = File.join(test_states, @options[:deployment])
      @options[:resume_file] = File.join(state_dir, File.basename(@main_feature))
      if File.directory?(state_dir)
        if File.exists?(@options[:resume_file])
          unless @options[:no_resume]
            puts "INFO: Resuming previous testcase..."
            if File.mtime(@options[:resume_file]) < File.mtime(@main_feature)
              warn "WARNING: testcase has been changed since state file." unless @main_feature =~ /\.combo\.rb$/
            end
          else
            puts "INFO: Scrapping previous testcase; Starting over..."
            File.delete(@options[:resume_file])
          end
        end
      else
        FileUtils.mkdir_p(state_dir)
      end
      if File.exists?(@options[:resume_file])
        puts "INFO: Confirmed resuming previous testcase, using paused tests..."
        my_yaml = YAML::load(IO.read(@options[:resume_file]))
        @tests_to_resume = my_yaml.first["tests"]
        @completed_features = my_yaml.first["completed_features"] || @completed_features
        @features_to_run = @features.keys - @completed_features
        @feature_in_progress = my_yaml.first["feature"]
      end
    end

    def run(*tests_to_run)
      print_to_readable_log = lambda do |feature, stage, test_name|
        str = "**  #{File.basename(feature)}: #{stage.to_s.upcase.gsub(/_|-/, ' ')} #{test_name}  **"
        @runner.write_readable_log("#{'*' * str.length}\n#{str}\n#{'*' * str.length}")
      end

      runner_exec_no_trace = lambda do |block|
        @runner.transaction(:do_not_trace) { @runner.instance_eval(&block) }
      end

      runner_exec = lambda do |block|
        @runner.instance_exec(&block)
      end

      @features_to_run = @features.keys
      check_for_resume
      if @completed_features.include?(@main_feature)
        if @feature_in_progress and @completed_features.include?(@feature_in_progress)
          @features_to_run.unshift(@features_to_run.delete(@feature_in_progress))
        end
      else
        @features_to_run.unshift(@features_to_run.delete(@main_feature))
      end
      @features_to_run.each { |feature|
        # Create Runner, initialize VirtualMonkey::log files
        if @options[:helpers]
          @options[:helpers].each { |helper| @options[:runner].class_eval(&helper) }
        end
        @runner = @options[:runner].new(@options[:deployment], @options)
        # Set up tests_to_run
        tests_to_run = @tests_to_resume if @tests_to_resume
        tests_to_run.compact!
        tests = get_keys(feature)
        tests.shuffle! if ::VirtualMonkey::config[:test_ordering] == "random"
        tests &= tests_to_run unless tests_to_run.empty?
        unless @tests_to_resume
          tests -= @options[:exclude_tests] unless @options[:exclude_tests].nil? || @options[:exclude_tests].empty?
        end
        # Add the tests to the tracelog
        VirtualMonkey::trace_log.first["tests"] = tests_to_run
        VirtualMonkey::trace_log.first["feature"] = feature
        VirtualMonkey::trace_log.first["completed_features"] = @completed_features
        @runner.write_readable_log("Completed features: #{@completed_features.join(", ")}")
        @runner.write_readable_log("Running feature: #{feature}")
        @runner.write_readable_log("Running tests: #{tests.join(", ")}")
        @runner.write_trace_log
        # Before
        if @options[:no_resume] && feature == @main_feature
          if @blocks[:hard_reset][feature]
            print_to_readable_log[feature, :hard_reset, nil]
            runner_exec_no_trace[@blocks[:hard_reset][feature]]
          end
        end
        if @features[feature]
          order = [:soft_reset, :hard_reset]
          order.reverse! if @features[feature] == :hard_reset
          order.each do |type|
            if @blocks[type][feature]
              print_to_readable_log[feature, type, nil]
              runner_exec_no_trace[@blocks[type][feature]]
              break
            end
          end
        end
        if @blocks[:before][feature] and @blocks[:before][feature][:once]
          unless VirtualMonkey::trace_log.first["run_once"]
            print_to_readable_log[feature, :before_all, :run_once]
            runner_exec_no_trace[@blocks[:before][feature][:once]]
            VirtualMonkey::trace_log.first["run_once"] = true
            @runner.write_trace_log
          end
        end
        if @blocks[:before][feature] and @blocks[:before][feature][:all]
          print_to_readable_log[feature, :before, :all]
          runner_exec[@blocks[:before][feature][:all]]
        end
        # Test
        tests.each { |key|
          [:before, :test, :after].each { |stage|
            if @blocks[stage][feature] and @blocks[stage][feature][key]
              print_to_readable_log[feature, stage, key]
              runner_exec[@blocks[stage][feature][key]]
            end
          }
        }
        # After
        if @blocks[:after][feature] and @blocks[:after][feature][:all]
          print_to_readable_log[feature, :after, :all]
          runner_exec[@blocks[:after][feature][:all]]
        end
        # Run completed, delete the resume file
        FileUtils.rm_rf @options[:resume_file]
        if @runner.done_resuming
          @completed_features << feature
          VirtualMonkey::trace_log = []
        else
          raise "FATAL: Never finished resuming, removing unclean resume file. Please run again with --no_resume"
        end
      }
    ensure
      # For being friendly to tests (multiple TestCase instances in one test)
      VirtualMonkey::trace_log = []
    end

    #
    # API
    #

    def set(var, *args, &block)
      if block
        ret = yield
        (ret.is_a?(Array) ? (args += ret) : (args << ret))
      end

      case var.class.to_s
      when "Symbol"
        case var
        when :runner
          if args.first.is_a?(Class) && args.first.to_s =~ /VirtualMonkey::Runner/
            if @options[var] and @options[var] != args.first
              raise "FATAL: Tried to set :runner to #{args.first} when already set to #{@options[var]}"
            end
            @options[var] = args.first
          else
            raise "FATAL: Need a VirtualMonkey::Runner Class!"
          end
        when :logs
          args.each { |log| @options[:additional_logs] << log if log.is_a?(String) }
          @options[:additional_logs].uniq!
        when :runner_options
          if args.first.is_a?(Hash)
            @options[var] ||= {}
            args.each { |key,val|
              warn "WARNING: overwriting runner_options '#{key}'" if @options[var][key]
              @options[var][key] = val
            }
          else
            raise "FATAL: :runner_options can only be set to a Hash!"
          end
        when :allow_meta_monkey
          @options[var] = true
        else
          warn "#{var} is not a valid option!"
        end
      when "String"
        @options[:runner_options] ||= {}
        warn "WARNING: overwriting runner_options '#{var}'" if @options[:runner_options][var]
        if args.length > 1
          @options[:runner_options][var] = args
        else
          @options[:runner_options][var] = args.first
        end
      else
        warn "#{var} is not a valid option!"
      end
    end

    def hard_reset(&block)
      warn "WARNING: overwriting hard_reset for feature '#{@current_file}'" if @blocks[:hard_reset][@current_file]
      @blocks[:hard_reset][@current_file] = block
    end

    def soft_reset(&block)
      warn "WARNING: overwriting soft_reset for feature '#{@current_file}'" if @blocks[:soft_reset][@current_file]
      @blocks[:soft_reset][@current_file] = block
    end

    def clean_start(&block)
      hard_reset(&block)
    end

    def before(*args, &block)
      @blocks[:before][@current_file] ||= {}
      if args.empty?
        warn "WARNING: overwriting universal before for feature '#{@current_file}'" if @blocks[:before][@current_file][:all]
        @blocks[:before][@current_file][:all] = block
      elsif args.length == 1 && args.first == :once
        warn "WARNING: overwriting run_once before for feature '#{@current_file}'" if @blocks[:before][@current_file][:once]
        @blocks[:before][@current_file][:once] = block
      else
        warn "WARNING: only Strings are allowed for test case names" if args.reject! { |test| !test.is_a?(String) }
        args.each { |test|
          warn "WARNING: overwriting before '#{test}' for feature '#{@current_file}'" if @blocks[:before][@current_file][test]
          @blocks[:before][@current_file][test] = block
        }
        # Uncomment the following lines to allow "before" blocks without corresponding "test" blocks
#        @all_keys -= args
#        @all_keys |= args
#        @keys_per_feature[@current_file] -= args
#        @keys_per_feature[@current_file] |= args
      end
    end

    def test(*args, &block)
      @blocks[:test][@current_file] ||= {}
      warn "WARNING: only Strings are allowed for test case names" if args.reject! { |test| !test.is_a?(String) }
      args.each { |test|
        warn "WARNING: overwriting test '#{test}' for feature '#{@current_file}'" if @blocks[:test][@current_file][test]
        @blocks[:test][@current_file][test] = block
      }
      @all_keys -= args
      @all_keys |= args
      @keys_per_feature[@current_file] -= args
      @keys_per_feature[@current_file] |= args
    end

    def after(*args, &block)
      @blocks[:after][@current_file] ||= {}
      if args.empty?
        warn "WARNING: overwriting universal after for feature '#{@current_file}'" if @blocks[:after][@current_file][:all]
        @blocks[:after][@current_file][:all] = block
      else
        warn "WARNING: only Strings are allowed for test case names" if args.reject! { |test| !test.is_a?(String) }
        args.each { |test|
          warn "WARNING: overwriting after '#{test}' for feature '#{@current_file}'" if @blocks[:after][@current_file][test]
          @blocks[:after][@current_file][test] = block
        }
        # Uncomment the following lines to allow "after" blocks without corresponding "test" blocks
#        @all_keys -= args
#        @all_keys |= args
#        @keys_per_feature[@current_file] -= args
#        @keys_per_feature[@current_file] |= args
      end
    end

    def helpers(&block)
      @options[:helpers] ||= []
      @options[:helpers] << block
    end

    def method_missing(sym, *args, &block)
      raise NoMethodError.new("undefined method '#{sym}' for #{inspect}:#{self.class}") unless @runner
      @runner.__send__(sym, *args, &block)
    end
  end
  TestCase.freeze
end
