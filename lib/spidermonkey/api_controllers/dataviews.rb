module VirtualMonkey
  module API
    class DataView < VirtualMonkey::API::BaseResource
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
      end
      private_class_method :write_cache

      def self.fields
        [
        ]
      end
      private_class_method :fields

      #
      # Constructor
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        task_uid = Time.now.strftime("%Y%m%d%H%M%S#{[rand(1000000).to_s].pack('m').chomp}")
        self.actions |= [
          {"rel" => "save"},
          {"rel" => "purge"},
        ]
        self.links |= [
          {"href" => self.class::PATH + "/#{task_uid}",
           "rel" => "self"},
        ]
        self["uid"] = task_uid
        self
      end

      #
      # API
      #
      public

      def self.index
        not_implemented # TODO - later
      end

      def self.create(opts={})
        not_implemented # TODO - later
      end

      def self.get(uid)
        not_implemented # TODO - later
      end

      def self.update(uid, opts={})
        not_implemented # TODO - later
      end

      def self.delete(uid)
        not_implemented # TODO - later
      end

      def self.save(uid)
        not_implemented # TODO - later
      end

      def self.purge(uid)
        not_implemented # TODO - later
      end

      def self.autocomplete
        not_implemented # TODO - later

        ret_hsh = {}
        fields.each do |field|
          ret_hsh[field] ||= []
          ret_hsh[field] |= listings.map { |record| record[field] }.compact
        end

        ret_hsh.each { |field,ary| ret_hsh[field].sort! }

        return ret_hsh
      end

      #
      # Unexposed API
      #
    end
  end
end
