module VirtualMonkey
  module API
    class Task < VirtualMonkey::API::BaseResource
      extend VirtualMonkey::API::StandardSimpleDBHelpers
      PATH = "#{VirtualMonkey::API::ROOT}/tasks".freeze
      ContentType = "application/vnd.rightscale.virtualmonkey.task"
      CollectionContentType = ContentType + ";type=collection"
      TEMP_STORE = File.join("", "tmp", "spidermonkey_tasks.json").freeze
      SDB_STORE = "virtualmonkey_tasks".freeze

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
          "command",
          "options",
          "subtask_hrefs",
          "shell",
#          "scheduled",
          "affinity",
          "name",
          "uid",
          "user",
        ]
      end
      private_class_method :fields

      def self.cron_edit_fields
        @@cron_edit_fields ||= CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
      end
      private_class_method :cron_edit_fields

      def self.valid_affinities
        ["parallel", "continue", "stop"]
      end
      private_class_method :valid_affinities

      def self.validate_parameters(hsh)
        unless (String === hsh["command"]) or (Array === hsh["subtask_hrefs"]) or (String === hsh["shell"])
          STDERR.puts(hsh.pretty_inspect)
          raise ArgumentError.new("#{PATH} requires a 'command' String, a 'subtask_hrefs' Array, or a 'shell' String")
        end
        if [hsh["subtask_hrefs"], hsh["command"], hsh["shell"]].count { |o| o } > 1
          STDERR.puts(hsh.pretty_inspect)
          raise ArgumentError.new("The 'command', 'subtask_hrefs', and 'shell' parameters are mutually exclusive")
        end
        if hsh["subtask_hrefs"] and not valid_affinities.include?(hsh["affinity"])
          STDERR.puts(hsh.pretty_inspect)
          msg = "#{PATH} requires a valid 'affinity' String when passing a 'subtask_hrefs' Array"
          msg += "\nValid affinities are: #{valid_affinities.join(", ")}"
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
        task_uid = Time.now.strftime("%Y%m%d%H%M%S#{[rand(1000000).to_s].pack('m').chomp}")
        self.actions |= [
          {"rel" => "save"},
          {"rel" => "purge"},
          {"rel" => "schedule"},
          {"rel" => "start"},
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
        cache = read_cache
        sdb_index.each do |item|
          uid = item["uid"]
          if cache[uid] && Chronic.parse(cache[uid]["updated_at"]) < Chronic.parse(item["updated_at"])
            cache[uid] = item
          end
        end
        write_cache(cache)
        cache.map { |uid,item_hash| new.deep_merge(item_hash) }
      end

      def self.create(opts={})
        # Check for required Arguments
        validate_parameters(opts)

        # Sanitize
        opts &= (fields | cron_edit_fields)

        # Check for Schedule options
        command = opts["command"]
        schedule_opts = opts & cron_edit_fields
        schedule_opts -= ["command"]
        opts -= cron_edit_fields
        opts["command"] = command

        # Get user data
        opts["user"] ||= rest_config_yaml[:user]

        # Read, Create, and Write record
        cache = read_cache
        new_record = self.new.deep_merge(opts.merge("scheduled" => false))
        cache[new_record.uid] = new_record
        write_cache(cache)

        # Schedule?
        self.schedule(new_record, schedule_opts) unless schedule_opts.empty?

        return new_record.uid
      end

      def self.get(uid)
        uid = normalize_uid(uid)
        record = self.from_json_file(TEMP_STORE, uid)
        record ||= sdb_read(uid)[uid]
        raise IndexError.new("#{self} #{uid} not found") unless record

        # Update Cache
        cache = read_cache
        if cache[uid] && Chronic.parse(cache[uid]["updated_at"]) < Chronic.parse(record["updated_at"])
          cache[uid] = record
        end
        write_cache(cache)
        record
      end

      def self.update(uid, opts={})
        uid = normalize_uid(uid)

        # Check for required Arguments
        validate_parameters(opts)

        # Sanitize
        opts &= (fields | cron_edit_fields)
        opts["updated_at"] = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")

        # Check for Schedule options
        command = opts["command"]
        schedule_opts = opts & cron_edit_fields
        schedule_opts -= ["command"]
        opts -= cron_edit_fields
        opts["command"] = command

        # Get user data NOTE: this means the person who updated takes control
        opts["user"] ||= rest_config_yaml[:user]

        # Read Cache
        cache = read_cache
        cache[uid] ||= sdb_read(uid)
        raise IndexError.new("#{self} #{uid} not found") unless cache[uid]
        cache[uid].deep_merge!(opts)

        # Reject old options if type has changed
        cache[uid] -= ["subtask_hrefs", "affinity", "shell"] if opts["command"]
        cache[uid] -= ["command", "options", "shell"] if opts["subtask_hrefs"]
        cache[uid] -= ["subtask_hrefs", "affinity", "command", "options"] if opts["shell"]

        # Check that the Update is valid
        validate_parameters(cache[uid])

        # Update Cache
        write_cache(cache)

        # Schedule?
        self.schedule(new_record, schedule_opts) unless schedule_opts.empty?

        return nil
      end

      # Deletes only from Cache
      def self.delete(uid)
        uid = normalize_uid(uid)
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache.delete(uid)
        write_cache(cache)
        nil
      end

      # Saves to SimpleDB NOTE: don't save "schedule" field
      def self.save(uid)
        uid = normalize_uid(uid)
        record = get(uid)

        record -= ["schedule"]
        sdb_write(record)
      end

      # Deletes from SimpleDB and Cache
      def self.purge(uid)
        uid = normalize_uid(uid)
        sdb_delete(uid)
        delete(uid)
      end

      def self.schedule(uid, opts={})
        uid = normalize_uid(uid)
        # Linux only for now
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache[uid]

        # Sanitize
        opts &= cron_edit_fields
        opts["updated_at"] = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")
        opts["scheduled"] = true
        opts.delete("command")

        # Read rest_connection settings
        settings = rest_config_yaml

        if File.writable?(VirtualMonkey::SYS_CRONTAB)
          cronedit_opts = (opts.map { |k,v| [k.to_sym, v] }.to_h) & CronEdit::CronEntry::DEFAULTS.keys

          base_url = "https://#{settings[:user]}:#{settings[:pass]}@127.0.0.1"
          path = "#{PATH}/#{uid}/start"
          cronedit_opts[:command] = "curl -x POST #{base_url}#{path}"


          crontab = VirtualMonkey::SYS_CRONTAB

          ct = CronEdit::FileCrontab.new(crontab, crontab)
          ct.add("#{uid}", cronedit_opts)
          ct.commit
        else
          STDERR.puts("File #{VirtualMonkey::SYS_CRONTAB} isn't writable! You cannot schedule tasks right now.")
          opts["scheduled"] = false
        end

        # Get user data NOTE: this means the person who updated takes control
        opts["user"] ||= settings[:user]

        cache[uid].deep_merge!(opts & ["updated_at", "scheduled", "user"])
        write_cache(cache)

        return nil
      end

      def self.start(uid, additional_opts={})
        uid = normalize_uid(uid)
        additional_opts &= fields

        # Get user data
        additional_opts["user"] ||= rest_config_yaml[:user]

        opts = additional_opts.merge("parent_task" => uid)
        parent_task = self.get(uid)

        case parent_task["affinity"]
        when "parallel"
          return parent_task["subtask_hrefs"].map { |subtask_href|
            # Get Subtask
            ret = []
            subtask = self.get(subtask_href)
            opts.merge!("parent_task" => subtask.uid)

            # Recurse & start
            if subtask["affinity"]
              ret += [self.start(subtask)]
            else
              ret += [VirtualMonkey::API::Job.create(opts)]
            end

            ret
          }.flatten.compact
        when "continue", "stop"
          subtask = self.get(parent_task["subtask_hrefs"].first)
          if subtask["affinity"]
            msg = "Tasks with affinity=#{parent_task["affinity"]} cannot have grandchild subtasks"
            raise VirtualMonkey::API::SemanticError.new(msg)
          end
          opts.merge!("parent_task" => subtask.uid, "callback_task" => uid)
          return VirtualMonkey::API::Job.create(opts)
        when nil then return VirtualMonkey::API::Job.create(opts)
        else
          msg = "Invalid 'affinity': #{parent_task["affinity"]}. Valid values: #{valid_affinities.inspect}"
          raise VirtualMonkey::API::SemanticError.new(msg)
        end
      end

      #
      # Unexposed API
      #
      def self.get_next_subtask_href(last_task_uid, managing_task_uid, status)
        last_task, managing_task = self.get(last_task_uid), self.get(managing_task_uid)
        if last_task && managing_task
          unless managing_task["affinity"] == "stop" && status != "passed"
            next_index = managing_task["subtask_hrefs"].index(last_task.href) + 1
            if next_index < managing_task["subtask_hrefs"].size
              return managing_task["subtask_hrefs"][next_index]
            end
          end
        end
        return nil
      end
    end
  end
end
