require 'git'

module VirtualMonkey
  module Command
    # Collateral commands
    @@command_flags.merge!("collateral" => [])
    def self.collateral(*args)
      self.init(*args)
      @@command = "collateral"

      unless class_variable_defined?("@@collateral_help_message")
        @@collateral_help_message = "  monkey collateral [options...]\n\n "
        @@collateral_help_message += @@available_commands[@@command.to_sym] + "\n"
        @@collateral_help_message += pretty_help_message(CollateralOptions)
      end

      @@last_command_line = "#{@@command} #{ARGV.join(" ")}"

      # Variable Initialization
      projects = VirtualMonkey::Manager::Collateral::Projects
      git_objs = projects.map { |project|
        g = nil
        if File.directory?(File.join(project.root_path, ".git"))
          g = Git.open(project.root_path)
        else
          g = Git.init(project.root_path)
        end
        [project.name, g]
      }.to_h
      printable_hash = git_objs.map { |proj,g|
        [File.basename(proj), {"origin" => g.config["remote.origin.url"], "branch" => g.current_branch}]
      }.to_h

      # Print Help?
      if ARGV.empty? or not (ARGV & ['--help', '-h', 'help']).empty?
        if ARGV.empty?
          puts pretty_help_message(printable_hash) unless printable_hash.empty?
        end
        puts "\n#{@@collateral_help_message}\n\n"
        exit(0)
      end

      # Subcommands
      subcommand = ARGV.shift
      improper_argument_error = word_wrap("FATAL: Improper arguments for command '#{subcommand}'.\n\n#{@@collateral_help_message}\n")

      case subcommand
      when "clone", "--clone", "-c"
        # Command line check
        error improper_argument_error if ARGV.length < 2
        repo_path, project_name = ARGV.shift(2)
        git_options ||= {}
        unless ARGV.empty?
          git_options = Trollop::options do
            opt :bare, '', :short => :none, :type => :boolean, :default => false
            opt :depth, '', :short => :none, :type => :integer
          end
        end

        # Command
        project_path = File.join(VirtualMonkey::COLLATERAL_TEST_DIR, project_name)
        error "FATAL: #{project_path} already exists!" if File.exists?(project_path)
        FileUtils.mkdir_p(VirtualMonkey::COLLATERAL_TEST_DIR)
        puts Git.clone(repo_path, project_path, git_options)
        # Hook up git_hooks dir
        if File.directory?(File.join(project_path, "git_hooks"))
          FileUtils.rm_rf(File.join(project_path, ".git", "hooks"))
          FileUtils.ln_s(File.join(project_path, "git_hooks"), File.join(project_path, ".git", "hooks"))
        end

        # Refresh Projects index
        VirtualMonkey::Manager::Collateral.refresh()

      when "init", "--init", "-i"
        # Command line check
        error improper_argument_error if ARGV.length != 1
        project_name = ARGV.shift(1)

        # Command
        project_path = File.join(VirtualMonkey::COLLATERAL_TEST_DIR, project_name)
        error "FATAL: #{project_path} already exists!" if File.exists?(project_path)
        FileUtils.mkdir_p(VirtualMonkey::COLLATERAL_TEST_DIR)
        # Init git dir
        puts Git.init(project_path)
        # Build project folders
        VirtualMonkey::Manager::Collateral::DIRECTORIES.each do |dir|
          FileUtils.mkdir_p(File.join(project_path, dir))
        end
        # Copy project_files from template folder
        proj_files = VirtualMonkey::Manager::Collateral::PROJECT_FILES.map do |f|
          File.join(VirtualMonkey::PROJECT_TEMPLATE_DIR, f)
        end
        FileUtils.cp_r(proj_files, project_path)
        # Hook up git_hooks dir
        if File.directory?(File.join(project_path, "git_hooks"))
          FileUtils.rm_rf(File.join(project_path, ".git", "hooks"))
          FileUtils.ln_s(File.join(project_path, "git_hooks"), File.join(project_path, ".git", "hooks"))
        end

        puts "\nTo generate new collateral, use 'monkey new_runner' or 'monkey import_deployment'\n\n".apply_color(:green)

      when "checkout", "--checkout", "-k"
        # Command line check
        error improper_argument_error if ARGV.length < 2
        project_name, refspec = ARGV.shift(2)
        git_options ||= {}
        unless ARGV.empty?
          git_options = Trollop::options do
            opt :force, '', :short => '-f', :type => :boolean, :default => false
          end
        end

        # Command
        project_path = File.join(VirtualMonkey::COLLATERAL_TEST_DIR, project_name)
        error "FATAL: #{project_path} doesn't exist!" unless File.exists?(project_path)
        FileUtils.mkdir_p(VirtualMonkey::COLLATERAL_TEST_DIR)
        puts git_objs[project_name].checkout(refspec)

        # Refresh Projects index
        VirtualMonkey::Manager::Collateral.refresh()

      when "pull", "--pull", "-p"
        # Command line check
        error improper_argument_error if ARGV.length < 1 || ARGV.length > 3
        project_name, remote, branch = ARGV.shift(3)

        # Command
        project_path = File.join(VirtualMonkey::COLLATERAL_TEST_DIR, project_name)
        error "FATAL: #{project_path} doesn't exist!" unless File.exists?(project_path)
        remote ||= 'origin'
        branch ||= 'master'
        FileUtils.mkdir_p(VirtualMonkey::COLLATERAL_TEST_DIR)
        puts git_objs[project_name].pull(remote, "#{remote}/#{branch}", nil)

        # Refresh Projects index
        VirtualMonkey::Manager::Collateral.refresh()

      when "list", "--list", "-l"
        # Command line check
        error improper_argument_error unless ARGV.empty?

        # Command
        message = ""
        if printable_hash.empty?
          message = "  No test collateral repos checked out.".apply_color(:yellow)
        else
          message = pretty_help_message(printable_hash)
        end
        puts "\n  monkey collateral list\n\n#{message}\n\n"

      when "delete", "--delete", "-d"
        # Command line check
        error improper_argument_error if ARGV.length != 1
        project_name = ARGV.shift(1)

        # Command
        project_path = File.join(VirtualMonkey::COLLATERAL_TEST_DIR, project_name)
        error "FATAL: #{project_path} doesn't exist!" unless File.exists?(project_path)
        if ask("Are you sure you want to delete #{project_name}?", lambda { |ans| ans =~ /^[yY]/ })
          FileUtils.rm_rf(project_path)
        else
          error "Aborting on user input."
        end

        # Refresh Projects index
        VirtualMonkey::Manager::Collateral.refresh()

      else
        error "FATAL: '#{subcommand}' is an invalid command.\n\n#{@@collateral_help_message}\n"
      end

      puts ("Command 'monkey #{@@last_command_line}' finished successfully.").apply_color(:green)
      reset()
    end
  end
end
