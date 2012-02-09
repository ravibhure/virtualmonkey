module VirtualMonkey
  module API
    class DataView < VirtualMonkey::API::BaseResource
      extend VirtualMonkey::API::StandardSimpleDBHelpers
      PATH = "#{VirtualMonkey::API::ROOT}/dataviews".freeze
      ContentType = "application/vnd.rightscale.virtualmonkey.dataview"
      CollectionContentType = ContentType + ";type=collection"
      TEMP_STORE = File.join("", "tmp", "spidermonkey_dataviews.json").freeze
      SDB_STORE = "virtualmonkey_dataviews".freeze

      #
      # Helper Methods
      #
      private

      def self.read_cache
        JSON::parse(IO.read(TEMP_STORE))
      rescue Errno::ENOENT, JSON::ParserError
        File.open(TEMP_STORE, "w") { |f| f.write("{}") }
        return {}
      rescue Errno::EBADF, IOError
        sleep 0.1
        retry
      end
      private_class_method :read_cache

      def self.write_cache(json_hash)
        File.open(TEMP_STORE, "w") { |f| f.write(json_hash.to_json) }
      rescue Errno::EBADF, IOError
        sleep 0.1
        retry
      end
      private_class_method :write_cache

      def self.fields
        @@fields ||= [
          "name",
          "display_type",

          # Filters to Freeze

          "user_email",
          "user_name",
          "mci_name",
          "mci_href",
          "mci_os",
          "mci_os_version",
          "mci_arch",
          "mci_rightlink",
          #"mci_hypervisor",
          "mci_rev",
          "mci_id",
          "servertemplate_name",
          "servertemplate_href",
          "servertemplate_rev",
          "servertemplate_id",
          "cloud_name",
          "cloud_id",
          "instancetype_name",
          "instancetype_href",
          "datacenter_name",
          "datacenter_href",
          "troop",
          "tags",
          "from_date",
          "to_date",
        ]
      end
      private_class_method :fields

      def self.valid_display_types
        ["spreadsheet"]
      end
      private_class_method :valid_display_types

      def self.validate_parameters(hsh)
        unless String === hsh["name"] && String === hsh["display_type"]
          STDERR.puts(hsh.pretty_inspect)
          raise ArgumentError.new("#{PATH} requires a 'name' String and a 'display_type' String")
        end
        unless valid_display_types.include?(hsh["display_type"])
          STDERR.puts(hsh.pretty_inspect)
          msg = "#{PATH} requires a valid 'display_type' String"
          msg += "\nValid display_types are: #{valid_display_types.join(", ")}"
          raise ArgumentError.new(msg)
        end
        true
      end
      private_class_method :validate_parameters

      #
      # Constructor
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        dataview_uid = Time.now.strftime("%Y%m%d%H%M%S#{[rand(1000000).to_s].pack('m').chomp}")
        self.actions |= [
          {"rel" => "save"},
          {"rel" => "purge"},
        ]
        self.links |= [
          {"href" => self.class::PATH + "/#{dataview_uid}",
           "rel" => "self"},
        ]
        self["uid"] = dataview_uid
        self
      end

      #
      # API
      #
      public

      def self.index
        read_cache.map { |uid,item_hash| new.deep_merge(item_hash) } | sdb_index
      end

      def self.create(opts={})
        # Check for required Arguments
        validate_parameters(opts)

        # Sanitize
        opts &= fields

        # Read, Create, and Write record
        cache = read_cache
        new_record = self.new.deep_merge(opts.merge("scheduled" => false))
        cache[new_record.uid] = new_record
        write_cache(cache)

        return new_record.uid
      end

      def self.get(uid)
        uid = normalize_uid(uid)
        record = self.from_json_file(TEMP_STORE, uid)
        record ||= sdb_read(uid)
        raise IndexError.new("#{self} #{uid} not found") unless record
        record
      end

      def self.update(uid, opts={})
        uid = normalize_uid(uid)

        # Check for required Arguments
        validate_parameters(opts)

        # Sanitize
        opts &= fields
        opts["updated_at"] = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")

        # Read Cache
        cache = read_cache
        cache[uid] ||= sdb_read(uid)
        raise IndexError.new("#{self} #{uid} not found") unless cache[uid]
        cache[uid].deep_merge!(opts)

        # Check that the Update is valid
        validate_parameters(cache[uid])

        # Update Cache
        write_cache(cache)

        return nil
      end

      def self.delete(uid)
        uid = normalize_uid(uid)
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache.delete(uid)
        write_cache(cache)
        nil
      end

      def self.save(uid)
        uid = normalize_uid(uid)
        record = get(uid)
        sdb_write(record)
      end

      def self.purge(uid)
        uid = normalize_uid(uid)
        sdb_delete(uid)
        delete(uid)
      end

      def self.autocomplete
        date_range = ["20110101", Time.now.strftime("%Y%m%d")]
        report_metadata = VirtualMonkey::API::Report.autocomplete(*date_range)
        ret_hsh = synchronize_with_rs_account.deep_merge(report_metadata)

        return ret_hsh
      end

      #
      # Unexposed API
      #
      def self.synchronize_with_rs_account
        # Note: User metadata, tags, from_date, to_date must be merged later
        @@sync_store || {}
        if (File.now - File.mtime(VirtualMonkey::Metadata::TEMP_STORE)) > 1.days
          @@sync_store = VirtualMonkey::Metadata.synchronize
        end
        @@sync_store
      end
    end
  end
end
