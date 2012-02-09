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

    module StandardHelpers # Extend this Module
      #
      # Helper Methods
      #
      def rest_config_yaml
        @@rest_config_yaml ||= YAML::load(IO.read(VirtualMonkey::REST_YAML))
      end

      def not_allowed
        msg = "Method `#{calling_method}' is not allowed on #{self}"
        raise VirtualMonkey::API::MethodNotAllowedError.new(msg)
      end

      def from_json_file(filepath, record=nil)
        file = JSON.parse(IO.read(filepath))
        if record
          return (file[record] ? self.new.deep_merge(file[record]) : nil)
        else
          return file.map { |json| self.new.deep_merge(json) }
        end
      rescue Errno::ENOENT, JSON::ParserError
        File.open(filepath, "w") { |f| f.write("{}") }
        retry
      rescue Errno::EBADF
        sleep 0.1
        retry
      end

      def normalize_uid(uid)
        case uid
        when self then return uid.uid
        when String then return uid.split(/\//).last
        else
          raise TypeError.new("can't convert #{uid.class} into UID")
        end
      end

      def new_s3_connection
        VirtualMonkey::Toolbox::new_s3_connection
      end

      def new_sdb_connection
        VirtualMonkey::Toolbox::new_sdb_connection
      end
    end

    module StandardSimpleDBHelpers
      def new_sdb_connection
        VirtualMonkey::Toolbox::new_sdb_connection
      end

      def ensure_domain_exists(domain)
        # If domain doesn't exist, create domain
        sdb = new_sdb_connection
        sdb.create_domain(domain) unless sdb.list_domains.body["Domains"].include?(domain)
      end

      def sdb_index
        ensure_domain_exists(self::SDB_STORE)
        sdb = new_sdb_connection
        begin
          current_raw_items = sdb.select("SELECT * from #{self::SDB_STORE}").body["Items"]
        rescue Excon::Errors::ServiceUnavailable
          warn "Got \"ServiceUnavailable\", retrying..."
          sleep 5
          retry
        end
        current_raw_items.map do |uid,hsh|
          json_mapping = {}
          hsh.reject! do |field,val|
            ret = false
            if field =~ /JSON\((\w*)\)\[([0-9]*)\]/ && $1 && $2
              json_mapping[$1] ||= []
              json_mapping[$1][$2.to_i] = val
              ret = true
            end
            ret
          end

          item = self.new.deep_merge(hsh)
          json_mapping.each { |field,ary| item[field] = JSON::parse(ary.join("")) }
          item
        end
      end

      def sdb_read(*uids)
        sdb_index & uids
      end

      def sdb_write(*data_to_write)
        data_to_write.flatten!
        sdb = new_sdb_connection
        begin
          ensure_domain_exists(self::SDB_STORE)
          current_items = sdb_index
          data = {}
          replace_data = {}
          data_to_write.each do |hsh|
            # Send all metadata that is a string (no arrays like "links" or "actions")
            current_item = current_items[hsh["uid"]]
            record = self.new.deep_merge(current_item).deep_merge(hsh)
            record.reject! { |field,val| val.is_a?(Array) || val.is_a?(Hash) }
            hsh.each do |field,val|
              if val.is_a?(Array) || val.is_a?(Hash)
                # Partition Attributes into 1024-byte chunks
                val.to_json.chunk(1024).each_with_index do |s,i|
                  record["JSON(#{field})[#{i}]"] = s
                end
              end
            end
            data[record["uid"]] = record
            replace_data[record["uid"]] = record.keys
          end

          # Partition Data into 25-item chunks
          data.chunk(25).each do |chunked_data|
            begin
              sdb.batch_put_attributes(self::SDB_STORE, chunked_data, (replace_data & chunked_data.keys))
            rescue Excon::Errors::ServiceUnavailable
              warn "Got \"ServiceUnavailable\", retrying..."
              sleep 5
              retry
            end
          end
        rescue Excon::Errors::ServiceUnavailable
          warn "Got \"ServiceUnavailable\", retrying..."
          sleep 5
          retry
        rescue Exception => e
          warn "Got \"#{e.message}\" from #{e.backtrace.join("\n")}"
        end
        nil
      end

      def sdb_delete(*uids)
        ensure_domain_exists(self::SDB_STORE)
        sdb = new_sdb_connection
        uids.each do |uid|
          begin
            sdb.delete_attributes(self::SDB_STORE, uid)
          rescue Excon::Errors::ServiceUnavailable
            warn "Got \"ServiceUnavailable\", retrying..."
            sleep 5
            retry
          end
        end
      end
    end

    class BaseResource < Hash
      #
      # Helper Methods
      #
      extend VirtualMonkey::API::StandardHelpers

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
        # XXX - hate base64 encoding stuff just cuz it doesn't render nicely
        Base64.encode64(self.pretty_inspect)
      end
    end
  end
end

# Auto-require Section
automatic_require(VirtualMonkey::API_CONTROLLERS_DIR)
