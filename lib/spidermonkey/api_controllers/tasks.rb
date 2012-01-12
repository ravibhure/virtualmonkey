module VirtualMonkey
  module API
    class Task < VirtualMonkey::API::BaseResource
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
      rescue Errno::EBADF
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
          "command",
          "options",
          "subtask_hrefs",
#          "scheduled",
          "affinity",
          "name",
          "uid",
          "user",
        ]
      end
      private_class_method :fields

      def self.valid_affinities
        ["parallel", "continue", "stop"]
      end
      private_class_method :valid_affinities

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
        read_cache.map { |uid,item_hash| new.deep_merge(item_hash) }
      end

      def self.create(opts={})
        # Check for required Arguments
        unless opts["command"].is_a?(String) or opts["subtask_hrefs"].is_a?(Array)
          STDERR.puts(opts.pretty_inspect)
          raise ArgumentError.new("#{PATH} requires a 'command' String or a 'subtask_hrefs' Array")
        end
        if opts["subtask_hrefs"] and opts["command"]
          STDERR.puts(opts.pretty_inspect)
          raise ArgumentError.new("The 'command' String and 'subtask_hrefs' Array are mutually exclusive")
        end
        if opts["subtask_hrefs"] and not valid_affinities.include?(opts["affinity"])
          STDERR.puts(opts.pretty_inspect)
          msg = "#{PATH} requires an 'affinity' String when passing a 'subtask_hrefs' Array"
          raise ArgumentError.new(msg)
        end

        # Sanitize
        opts &= (fields | CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s })

        # Check for Schedule options
        command = opts["command"]
        schedule_opts = opts & CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
        schedule_opts -= ["command"]
        opts -= CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
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
        raise IndexError.new("#{self} #{uid} not found") unless record
        record
      end

      def self.update(uid, opts={})
        uid = normalize_uid(uid)

        # Sanitize
        opts &= (fields | CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s })
        opts["updated_at"] = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")

        # Check for Schedule options
        command = opts["command"]
        schedule_opts = opts & CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
        schedule_opts -= ["command"]
        opts -= CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
        opts["command"] = command

        # Get user data NOTE: this means the person who updated takes control
        opts["user"] ||= rest_config_yaml[:user]

        # Read Cache
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache[uid]
        cache[uid].deep_merge!(opts)

        # Check that the Update is valid
        unless cache[uid]["command"].is_a?(String) or cache[uid]["subtask_hrefs"].is_a?(Array)
          raise ArgumentError.new("#{PATH} requires a 'command' String or a 'subtask_hrefs' Array")
        end
        if cache[uid]["subtask_hrefs"] and cache[uid]["command"]
          raise ArgumentError.new("The 'command' String and 'subtask_hrefs' Array are mutually exclusive")
        end
        if cache[uid]["subtask_hrefs"] and not valid_affinities.include?(cache[uid]["affinity"])
          msg = "#{PATH} requires an 'affinity' String when using a 'subtask_hrefs' Array"
          raise ArgumentError.new(msg)
        end

        # Update Cache
        write_cache(cache)

        # Schedule?
        self.schedule(new_record, schedule_opts) unless schedule_opts.empty?

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
        # Saves to SimpleDB NOTE: don't save "schedule" field
        not_implemented # TODO - later
      end

      def self.purge(uid)
        uid = normalize_uid(uid)
        # Deletes from SimpleDB and Cache
        not_implemented # TODO - later
      end

      def self.schedule(uid, opts={})
        uid = normalize_uid(uid)
        # Linux only for now
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache[uid]

        # Sanitize
        opts &= CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
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
