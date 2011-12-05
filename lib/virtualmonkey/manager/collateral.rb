#
# VERY important patches needed to sandbox runners
#

# Need to allow transparent access to constants defined elsewhere in the framework
class Class
  def const_missing(sym)
    namespace = "#{self}"
    while namespace =~ /::/
      namespace = "#{namespace.to_s.split("::")[1..-1].join("::")}"
      if namespace_defined?(namespace)
        return namespace_get(namespace).const_get(sym)
      end
    end
    err_msg = "uninitialized constant " + [(self == Object ? nil : "#{self}"), sym].compact.join("::")
    raise NameError.new(err_msg)
  end

  def namespace_defined?(str)
    str.to_s.split("::").inject(Kernel.const_get("Object")) do |ns,name|
      return false unless ns.const_defined?(name)
      ns.const_get(name)
    end
    true
  end

  def namespace_get(str)
    str.to_s.split("::").inject(Kernel.const_get("Object")) { |ns,name| ns.const_get(name) }
  end
end

# Need to allow transparent access to constants defined elsewhere in the framework
class Module
  def const_missing(sym)
    namespace = "#{self}"
    while namespace =~ /::/
      namespace = "#{namespace.to_s.split("::")[1..-1].join("::")}"
      if namespace_defined?(namespace)
        return namespace_get(namespace).const_get(sym)
      end
    end
    err_msg = "uninitialized constant " + [(self == Object ? nil : "#{self}"), sym].compact.join("::")
    raise NameError.new(err_msg)
  end

  def namespace_defined?(str)
    str.to_s.split("::").inject(Kernel.const_get("Object")) do |ns,name|
      return false unless ns.const_defined?(name)
      ns.const_get(name)
    end
    true
  end

  def namespace_get(str)
    str.to_s.split("::").inject(Kernel.const_get("Object")) { |ns,name| ns.const_get(name) }
  end
end

#
# Manager Code
#

module VirtualMonkey
  class CollateralProject
    attr_accessor :root_path, :gemfile, :paths
    attr_reader :features, :cloud_variables, :common_inputs, :lists, :troops, :runners, :mixins

    def self.require_within(filename)
      @@required_within_files ||= {}
      @@required_within_files[self.to_s] ||= []
      filename = filename + ".rb" unless filename =~ /\.rb$/
      if @@required_within_files[self.to_s].include?(filename)
        return false
      else
        self.class_eval(File.read(filename), filename, 1)
        @@required_within_files[self.to_s] << filename
        return true
      end
    end

    def self.load_within(filename)
      filename = filename + ".rb" unless filename =~ /\.rb$/
      self.class_eval(File.read(filename), filename, 1)
    end

    def self.require(filename)
      Kernel.require(filename)
    rescue LoadError => e
      begin
        gem_spec = Gem::Specification.find_by_name(filename)
        $LOAD_PATH.unshift(Dir.glob(gem_spec.lib_dirs_glob()))
        $LOAD_PATH.unshift($LOAD_PATH.delete("lib"))
        $LOAD_PATH.flatten!
        $LOAD_PATH.compact!
        Kernel.require(filename)
      rescue Gem::LoadError => e
        self.require_within(filename)
      end
    end

    def self.load(filename, wrap=false)
      Kernel.load(filename, wrap)
    rescue LoadError => e
      self.load_within(filename)
    end

    def self.automatic_require_within(full_path)
      some_not_included = true
      files = Dir.glob(File.join(File.expand_path(full_path), "**"))
      retry_loop = 0
      last_err = nil
      while some_not_included and retry_loop <= (files.size ** 2) do
        begin
          some_not_included = false
          for f in files do
            val = require_within(f.chomp(".rb")) if f =~ /\.rb$/
            some_not_included ||= val
          end
        rescue NameError => e
          last_err = e
          raise unless "#{e}" =~ /uninitialized constant/i
          some_not_included = true
          files.push(files.shift)
        end
        retry_loop += 1
      end
      if some_not_included
        warn "Couldn't auto-include all files in #{File.expand_path(full_path)}"
        raise last_err
      end
    end

    def initialize(root_path)
      @root_path = root_path
      @gemfile = File.join(root_path, "Gemfile")
      @paths = VirtualMonkey::Manager::Collateral::DIRECTORIES.map_to_h { |dir| File.join(root_path, dir) }

      self.class.automatic_require_within(VirtualMonkey::RUNNER_CORE_DIR)
      # Check directory structure
      correct_structure = @paths.values.reduce(true) { |bool,path| bool && File.directory?(path) }
      unless correct_structure
        msg = "\nFATAL: Collateral '#{self.name}' has a bad directory structure. "
        msg += "It should have the following directories:\n"
        msg += VirtualMonkey::Manager::Collateral::DIRECTORIES.join("\n")
        warn msg
      end

      # Load Gems
      if gemfile?
        `cd #{root_path.inspect}; bundle install --system`
        raise "Failed to install gems for '#{root_path}'." unless $?.to_i == 0
        Gem.refresh
      end

      # Check that Runners and Mixins are defined only once
      msg = `cd #{VirtualMonkey::ROOTDIR}; ruby git_hooks/pre-commit-chk-collateral #{File.basename(root_path)} 2>&1`
      raise "'#{root_path}' failed Runner Checks:\n#{msg}" unless $?.to_i == 0

      self.class.automatic_require_within(@paths["mixins"])
      self.class.automatic_require_within(@paths["runners"])

      @features = Dir.glob(File.join(@paths["features"], "**", "*.rb"))
      @cloud_variables = Dir.glob(File.join(@paths["cloud_variables"], "**", "*.json"))
      @common_inputs = Dir.glob(File.join(@paths["common_inputs"], "**", "*.json"))
      @lists = Dir.glob(File.join(@paths["lists"], "**", "*.json"))
      @troops = Dir.glob(File.join(@paths["troops"], "**", "*.json"))

      @mixins = self.class::VirtualMonkey::Mixin.constants.map { |const|
        [const, "Mixin::#{const}", "VirtualMonkey::Mixin::#{const}"]
      }.flatten

      @runners = self.class::VirtualMonkey::Runner.constants.map { |const|
        [const, "Runner::#{const}", "VirtualMonkey::Runner::#{const}"]
      }.flatten

      @all_files = Dir.glob(File.join(@root_path, "**", "*.*")).map { |file| File.expand_path(file) }
      self
    end

    def gemfile?
      File.exists?(@gemfile)
    end

    def find_name(name=nil)
      ret = @all_files.dup
      ret.reject! { |file_path| file_path !~ /#{name}/ } if name
      ret
    end

    def name
      File.basename(@root_path)
    end
  end
end

module VirtualMonkey
  module Runner
    def self.const_missing(sym)
      proj = VirtualMonkey::Command::selected_project
      proj ||= VirtualMonkey::Manager::Collateral.get_project_from_constant(sym.to_s)
      VirtualMonkey::Command::selected_project ||= proj
      unless VirtualMonkey::Command::selected_project.nil?
        return (VirtualMonkey::Command::selected_project.class)::VirtualMonkey::Runner.const_get(sym)
      end
      err_msg = "uninitialized constant " + [(self == Object ? nil : "#{self}"), sym].compact.join("::")
      raise NameError.new(err_msg)
    end
  end

  module Mixin
    def self.const_missing(sym)
      proj = VirtualMonkey::Command::selected_project
      proj ||= VirtualMonkey::Manager::Collateral.get_project_from_constant(sym.to_s)
      VirtualMonkey::Command::selected_project ||= proj
      unless VirtualMonkey::Command::selected_project.nil?
        return (VirtualMonkey::Command::selected_project.class)::VirtualMonkey::Mixin.const_get(sym)
      end
      err_msg = "uninitialized constant " + [(self == Object ? nil : "#{self}"), sym].compact.join("::")
      raise NameError.new(err_msg)
    end
  end

  module Project
  end

  module Manager
    module Collateral
      DIRECTORIES = %w{cloud_variables common_inputs features lists mixins runners troops}.freeze
      PROJECT_FILES = %w{git_hooks .gitignore Gemfile LICENSE README.rdoc}.freeze
      Projects = []

      def self.get_project_from_file(file_path)
        Projects.detect { |proj| proj.find_name(file_path).to_s =~ /#{file_path}/ }
      end

      def self.get_project_from_constant(const)
        Projects.detect { |proj| proj.runners.include?(const) || proj.mixins.include?(const) }
      end

      def self.all_features
        Projects.map { |proj| proj.features }
      end

      def self.all_cloud_variables
        Projects.map { |proj| proj.cloud_variables }
      end

      def self.all_common_inputs
        Projects.map { |proj| proj.common_inputs }
      end

      def self.all_lists
        Projects.map { |proj| proj.lists }
      end

      def self.all_troops
        Projects.map { |proj| proj.troops }
      end

      def self.[](proj_name)
        Projects.detect { |proj| proj.name == name }
      end

      def self.refresh
        project_dir_ary = Dir.glob(File.join(VirtualMonkey::COLLATERAL_TEST_DIR, "*"))
        project_ary = project_dir_ary.map do |p|
          class_name = File.basename(p).camelcase
          unless VirtualMonkey::Project.const_defined?(class_name)
            VirtualMonkey::Project.const_set(class_name, Class.new(VirtualMonkey::CollateralProject))
          end
          project_class = VirtualMonkey::Project.const_get(class_name)
          ret = nil
          begin
            ret = project_class.new(p)
          rescue Exception => e
            warn "WARNING: Could not initialize #{project_class}: #{e.message}\n#{e.backtrace.join("\n")}"
          end
          ret
        end
        Projects.replace(project_ary.compact)
      end

      # Initialize Projects array
      refresh()
    end
  end
end
