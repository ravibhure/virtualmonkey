class MessageCheck
  attr_accessor :logfile

  WHITELIST = "whitelist"
  BLACKLIST = "blacklist"
  NEEDLIST = "needlist"
  LISTS = [WHITELIST, BLACKLIST, NEEDLIST]

  # @db = { "whitelist": [
  #           ["/var/log/messages", ".*", "..."],
  #           ["/var/log/mysql.err", ".*", "..."]
  #         ],
  #         "blacklist": ...
  #       }

  def initialize(lists, strict=false)
#    @sdb = Fog::AWS::SimpleDB.new(:aws_access_key_id => Fog.credentials[:aws_access_key_id_test],
#                                  :aws_secret_access_key => Fog.credentials[:aws_secret_access_key_test])
#    domain_list = @sdb.list_domains.body['Domains']
    @db = {}
    @strict = strict
    @logfile = "/var/log/messages"
    @context = 5
    load_lists(lists)
  end

  # Given a list of ServerTemplates, returns a full-coverage list of logs that need to be audited
  def logs_to_check(server_templates)
    ret = {}
    server_templates.each do |st|
      LISTS.each { |list|
        @db[list].each do |logfile,st_rgx,msg_rgx|
          if st.nickname =~ /#{st_rgx}/i
            ret[st.href] ||= []
            ret[st.href] << logfile
          end
        end
      }
    end
    ret.each { |k,v| ret[k].uniq! }
    return ret
  end

  # Encapsulates the logic for inserting a new list entry
  def add_to_list(list, logfile_to_be, st_rgx_to_be, msg_rgx_to_be)
    # Do a union with existing lists to abstract which server templates should match
    entry_to_be = {'st' => st_rgx_to_be, 'msg' => msg_rgx_to_be}
    @db[list].each { |logfile,st_rgx,msg_rgx|
      if msg_rgx == msg_rgx_to_be and logfile == logfile_to_be
        entry_to_be['st'] = lcs(st_rgx, entry_to_be['st'])
      end
    }
    @db[list].reject! { |logfile,st_rgx,msg_rgx| msg_rgx == msg_rgx_to_be }
    @db[list] << [logfile_to_be, entry_to_be['st'], entry_to_be['msg']]
  end

  # Loads lists from json files and from runner list initializers
  def load_lists(lists = {})
    LISTS.each { |l|
      proj = VirtualMonkey::Command::selected_project
      @db[l] = JSON::parse(IO.read(File.join(proj.paths["lists"], "#{l}.json")))
      if lists[l]
        @db[l] ||= []
        lists[l].each { |logfile,st_rgx,msg_rgx|
          add_to_list(l, logfile, st_rgx, msg_rgx) unless @db[l].include?([logfile, st_rgx, msg_rgx])
        }
      end
    }
  end

  # Writes current db out to json files
  def save_db
    LISTS.each { |list|
      list_out = @db[list].to_json(:indent => "  ", :object_nl => "\n", :array_nl => "\n")
      proj = VirtualMonkey::Command::selected_project
      File.open(File.join(proj.paths["lists"], "#{list}.json"), "w") { |f| f.write(list_out) }
    }
  end

  # Returns nil or the the first matched list entry for a given message
  def match?(msg, st_name, list)
    res = @db[list].select { |logfile,st_rgx,msg_rgx|
      logfile == @logfile and msg =~ /#{msg_rgx}/i and st_name =~ /#{st_rgx}/i
    }
    return res.first
  end

  # Returns nil or the needlist entries that DID NOT match any message
  def needlist_check(match_list, st_name)
    return [] unless @db[NEEDLIST].length > 0
    ret_list = @db[NEEDLIST].dup
    match_list.each { |msg|
      ret_list.reject! { |logfile,st_rgx,msg_rgx|
        logfile != @logfile or st_name !~ /#{st_rgx}/i or msg =~ /#{msg_rgx}/i
      }
    }
    return ret_list
  end

  # Encapsulates the formatting for printing matches and their context
  def print_entry(entry, msg = nil)
    ret = ""
    if msg
      ret += "=" * msg.length + "\n"
      ret += "#{msg}\n"
      ret += "=" * msg.length + "\n"
    end
    entry.each { |line| ret += "#{line}\n" }
    ret
  end

  # The meat.
  def check_messages(object, interactive = false, log_file = @logfile)
    @logfile = log_file
    print_msg = ""
    print_msg = STDOUT if interactive
    if object.is_a?(Array)
      # Check each element
      object.each { |i| print_msg << check_messages(i, interactive) + "\n" }
    elsif object.is_a?(Deployment)
      # Check each Server
      print_msg << "Checking \"#{@logfile}\" in Deployment \"#{object.nickname}\"...\n"
      object.servers_no_reload.each { |s| print_msg << check_messages(s, interactive) + "\n" }
    elsif object.is_a?(Server) or object.is_a?(ServerInterface)
      # Check the logs
      print_msg << "Checking \"#{@logfile}\" for Server \"#{object.nickname}\"...\n"
      messages = object.spot_check_command("cat #{@logfile}", nil, object.reachable_ip, true)[:output].split("\n")
      st = ServerTemplate.find(object.server_template_href)

      # needlist
      n_msg_start = "ERROR: NEEDLIST entry didn't match any messages:"
      need_unmatches = needlist_check(messages, st.nickname)
      num_n_entries = @db[NEEDLIST].select { |logfile,st_rgx,msg_rgx|
        logfile == @logfile and st.nickname =~ /#{st_rgx}/i
      }
      unless interactive
        need_unmatches.each { |logfile,st_rgx,msg_rgx| print_msg << "#{n_msg_start} [#{st_rgx}, #{msg_rgx}]\n" }
      end

      # blacklist
      b_msg_start = "ERROR: BLACKLIST entry matched:"
      black_matches = []
      messages.each_index do |i|
          black_matches << messages[(i-@context)..(i+@context)] if match?(messages[i], st.nickname, BLACKLIST)
      end
      num_b_entries = @db[BLACKLIST].select { |logfile,st_rgx,msg_rgx|
        logfile == @logfile and st.nickname =~ /#{st_rgx}/i
      }

      # whitelist
      w_msg_start = "WARNING: WHITELIST entry matched:"
      if black_matches.length > 0 and not @strict
        white_matches = black_matches.select { |entry| match?(entry[@context], st.nickname, WHITELIST) }
        num_w_entries = @db[WHITELIST].select { |logfile,st_rgx,msg_rgx|
          logfile == @logfile and st.nickname =~ /#{st_rgx}/i
        }
        unless interactive
          white_matches.each { |entry| print_msg << print_entry(entry, w_msg_start) }
          (black_matches - white_matches).each { |entry| print_msg << print_entry(entry, b_msg_start) }
        end
      else
        unless interactive
          black_matches.each { |entry|
            print_msg << print_entry(entry, b_msg_start)
            print_msg << "NOTE: WHITELIST has entry for previous message\n" if match?(entry[@context], st.nickname, WHITELIST)
          }
        end
      end
      # print a summary
      summary_msg = "Log Audit Summary for \"#{@logfile}\":"
      print_msg << "#{"="*summary_msg.size}\n#{summary_msg}\n#{"="*summary_msg.size}\n"
      print_msg << "Total Log Messages:   #{messages.size}\n\n"
      print_msg << "Needlist Entries:     #{num_n_entries.size}\n" if need_unmatches
      print_msg << "Needlist Non-matches: #{need_unmatches.size}\n\n" if need_unmatches
      print_msg << "Blacklist Entries:    #{num_b_entries.size}\n" if black_matches
      print_msg << "Blacklist Matches:    #{black_matches.size}\n\n" if black_matches
      print_msg << "Whitelist Entries:    #{num_w_entries.size}\n" if white_matches
      print_msg << "Whitelist Matches:    #{white_matches.size}\n\n" if white_matches

      # Interactive training for the matches
      if interactive && tty?
        case ask("Review (U)nmatched, (B)lacklisted, (W)hitelisted, or (A)ll entries?")
        when /^[uU]/
          messages_reference = []
          messages.each_index do |i|
            messages_reference << messages[(i-@context)..(i+@context)] unless match?(messages[i], st.nickname, BLACKLIST)
          end
          messages_reference -= white_matches if white_matches
          messages_reference.reject! { |entry| match?(entry[@context], st.nickname, NEEDLIST) }
          puts "Reviewing unmatches entries..."
        when /^[bB]/
          messages_reference = black_matches.dup
          messages_reference -= white_matches if white_matches
          puts "Reviewing blacklisted entries..."
        when /^[wW]/
          if white_matches
            messages_reference = white_matches.dup
            puts "Reviewing whitelisted entries..."
          else
            messages_reference = []
            messages.each_index do |i|
              messages_reference << messages[(i-@context)..(i+@context)]
            end
            puts "No whitelisted entries, reviewing all entries..."
          end
        else
          messages_reference = []
          messages.each_index do |i|
            messages_reference << messages[(i-@context)..(i+@context)]
          end
          puts "Reviewing all entries..."
        end
        list_to_classify = messages_reference
        while list_to_classify.first
          entry = list_to_classify.shift
          terminal_width = (tty_width || 80).to_i
          puts "#{"*" * terminal_width}\n#{print_entry(entry)}#{"*" * terminal_width}"
          case ask("(B)lacklist, (W)hitelist, (N)eedlist, or (I)gnore?")
          when /^[bB]/
            puts "Adding to blacklist..."
            confirmed = false
            while not confirmed
              message_regex = ask("Enter a regular expression for matching the above line:")
              # Verify that this regex only covers what should be covered
              verify = messages.select { |line| line =~ /#{message_regex}/i }
              if verify.size != 1
                confirmed = ask("Adding \"#{message_regex}\" would blacklist #{verify.size} current entries. Are you sure you want to add it? (y/n)", lambda { |ans| true if ans =~ /^[yY]{1}/ })
              end
            end
            add_to_list(BLACKLIST, @logfile, st.nickname, message_regex)
            list_to_classify |= messages_reference.select { |entry| match?(entry[@context], st.nickname, BLACKLIST) }
            list_to_classify -= list_to_classify.select { |entry| match?(entry[@context], st.nickname, WHITELIST) }
            puts "Added to blacklist."
          when /^[wW]/
            puts "Adding to whitelist..."
            confirmed = false
            while not confirmed
              message_regex = ask("Enter a regular expression for matching the above line:")
              # Verify that this regex only covers what should be covered
              verify = list_to_classify.select { |line| line =~ /#{message_regex}/i }
              if verify.size != 1
                confirmed = ask("Adding \"#{message_regex}\" would whitelist #{verify.size} flagged entries. Are you sure you want to add it? (y/n)", lambda { |ans| true if ans =~ /^[yY]{1}/ })
              end
            end
            add_to_list(WHITELIST, @logfile, st.nickname, message_regex)
            list_to_classify.reject! { |entry| entry[@context] =~ /#{message_regex}/i }
            puts "Added to whitelist."
          when /^[nN]/
            puts "Adding to needlist..."
            message_regex = ask("Enter a regular expression for matching the above line:")
            add_to_list(NEEDLIST, @logfile, st.nickname, message_regex)
            puts "Added to needlist."
          else
            puts "Ignoring..."
          end
        end
      end
      save_db
    else
      raise "check_messages takes either Deployment or Server objects!"
    end
    return print_msg unless interactive
    ""
  end

  def lcs(first, second)
    MessageCheck.lcs(first, second)
  end

  # Longest Common Subsequence from http://rosettacode.org/
  # Modified to create regular expressions instead of raw subsequences
  # NOTE: Not a perfect solution...watch out for '\' and (".*a.+b.*", "a\000bgoo") -> ".*a\000b.*"
  def self.lcs(first, second)
    a, b = first, second
    a = first.split(/\.(\*|\+)/).join("\000") if first =~ /\.(\*|\+)/
    b = second.split(/\.(\*|\+)/).join("\000") if second =~ /\.(\*|\+)/
    lengths = Array.new(a.size+1) { Array.new(b.size+1) { 0 } }
    # row 0 and column 0 are initialized to 0 already
    a.split('').each_with_index { |x, i|
      b.split('').each_with_index { |y, j|
        if x == y
          lengths[i+1][j+1] = lengths[i][j] + 1
        else
          lengths[i+1][j+1] = [lengths[i+1][j], lengths[i][j+1]].max
        end
      }
    }
    # read the substring out from the matrix
    result = "*."
    x, y = a.size, b.size
    previous_found = false
    while x != 0 and y != 0
      if lengths[x][y] == lengths[x-1][y]
        x -= 1
        if previous_found
          result += "+." #result will be reversed later
          previoud_found = false
        end
      elsif lengths[x][y] == lengths[x][y-1]
        y -= 1
        if previous_found
          result += "+." #result will be reversed later
          previoud_found = false
        end
      else
        # assert a[x-1] == b[y-1]
        result << a[x-1]
        x -= 1
        y -= 1
        previoud_found = true
      end
    end
    result << "*."
    result.reverse
  end
end
