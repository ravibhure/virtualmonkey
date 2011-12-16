progress_require('algorithms')

module VirtualMonkey
  @@daemons = []
  @@daemon_queue = Containers::PriorityQueue.new()

  def self.daemons
    @@daemons ||= []
  end

  def self.daemon_queue
    @@daemon_queue ||= Containers::PriorityQueue.new()
  end

  module API
    class SemanticError < StandardError
    end

    class MethodNotAllowedError < StandardError
    end

    class BaseResource < Hash
      #
      # Helper Methods
      #
      def self.rest_config_yaml
        @@rest_config_yaml ||= YAML::load(IO.read(VirtualMonkey::REST_YAML))
      end

      def self.not_allowed
        msg = "Method `#{calling_method}' is not allowed on #{self}"
        raise VirtualMonkey::API::MethodNotAllowedError.new(msg)
      end

      def self.from_json_file(filepath, record=nil)
        file = JSON.parse(IO.read(filepath))
        self.new.deep_merge((record ? file[record] : file))
      end

      def self.normalize_uid(uid)
        case uid
        when self then return uid.uid
        when String then return uid.split(/\//).last
        else
          raise TypeError.new("can't convert #{uid.class} into UID")
        end
      end

      #
      # Standard CRUD REST APIs
      #

      def self.index()
        not_allowed
      end

      def self.create(params={})
        not_allowed
      end

      def self.get(uid)
        not_allowed
      end

      def self.update(uid, params={})
        not_allowed
      end

      def self.delete(uid)
        not_allowed
      end

      #
      # Instance Methods
      #

      def initialize(*args, &block)
        super(*args, &block)
        self["links"] ||= []
        self["actions"] ||= []
        created = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")
        self["created_at"] ||= created
        self["updated_at"] ||= created.dup
        self
      end

      def actions
        self["actions"]
      end

      def actions=(val)
        self["actions"] = val
      end

      def links
        self["links"]
      end

      def links=(val)
        self["links"] = val
      end

      def href
        link = self["links"].detect { |h| h["rel"] == "self" }
        link.nil? ? nil : link["href"]
      end

      def uid
        self["uid"]
      end

      def deep_merge(second)
        result = dup
        result.deep_merge!(second)
        result
      end

      def deep_merge!(second)
        raise TypeError.new("can't convert #{second.class} into Hash") unless Hash === second
        super(second)
        ["actions", "links", "created_at", "updated_at", "uid"].each do |field|
          self[field] = (second[field] || self[field]) if second.keys.include?(field) || keys.include?(field)
        end
        ["actions", "links"].each do |field|
          self[field].uniq_by! { |hsh| hsh["rel"] }
        end
      end

      def render()
        self.pretty_inspect
        # TODO - later
      end
    end
  end
end

# Auto-require Section
automatic_require(VirtualMonkey::API_CONTROLLERS_DIR)
