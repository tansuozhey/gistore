require 'pathname'
require 'gistore/error'

if RUBY_VERSION < '1.9'
  require 'open4'
else
  require 'open3'
end

module Gistore

  class <<self
    def git_cmd
      @git_cmd ||= begin
        git_path = which "git"
        unless git_path
          abort "Please install git first."
        else
          git_path.to_s
        end
      end
    end

    def git_version
      @git_version ||= begin
        shellout(git_cmd, "--version",
                 :without_locale => true) do |io|
          if io.read.strip =~ /^git version (.*)/
            $1.split('.').map(&:to_i)
          end
        end
      end
    end

    def git_version_compare(v1, v2=nil)
      if v2
        current_version = v1.is_a?(Array) ? v1.dup : v1.split('.').map(&:to_i)
        check_version = v2.is_a?(Array) ? v2.dup : v2.split('.').map(&:to_i)
      else
        current_version = git_version.dup
        check_version = v1.is_a?(Array) ? v1.dup : v1.split('.').map(&:to_i)
      end
      current_version.each do |current|
        check = check_version.shift.to_i
        result = current <=> check
        return result if result != 0
      end
      check_version.shift ? -1 : 0
    end

    def which cmd, path=ENV['PATH']
      dir = path.split(File::PATH_SEPARATOR).find {|p| File.executable? File.join(p, cmd)}
      Pathname.new(File.join(dir, cmd)) unless dir.nil?
    end

    def shellout(*args, &block)
      if Hash === args.last
        options = args.pop.dup
      else
        options = {}
      end
      options[:stdout_only] = true
      args << options
      self.popen3(*args, &block)
    end

    def shellpipe(*args, &block)
      if Hash === args.last
        options = args.pop.dup
      else
        options = {}
      end
      args << options unless options.empty?
      self.popen3(*args, &block)
    end

    def system(*args, &block)
      fork do
        block.call if block_given?
        args.map!{|arg| arg.to_s}
        exec(*args) rescue nil
        # never gets here unless raise some error (exec failed)
        exit! 1
      end
      Process.wait
      $?.success?
    end

    # Same like system but with exceptions
    def safe_system(*args, &block)
      unless Gistore.system(*args, &block)
        args = args.map{ |arg| arg.to_s.gsub " ", "\\ " } * " "
        raise CommandReturnError, "Failure while executing: #{args}"
      end
    end

    # prints no output
    def quiet_system(*args)
      Gistore.system(*args) do
        # Redirect output streams to `/dev/null` instead of closing as some programs
        # will fail to execute if they can't write to an open stream.
        $stdout.reopen('/dev/null')
        $stderr.reopen('/dev/null')
      end
    end

    if RUBY_VERSION < '1.9'

      def popen3(*cmd, &block)
        if Hash === cmd.last
          options = cmd.pop.dup
        else
          options = {}
        end
        result = nil
        pid, stdin, stdout, stderr = nil
        begin
          pid, stdin, stdout, stderr = Open4.popen4(*cmd)
          if options[:stdout_only]
            stdin.close
            result = block.call(stdout) if block_given?
          else
            result = block.call(stdin, stdout, stderr) if block_given?
          end
          ignored, status = Process::waitpid2 pid
          if options[:check_return] and status and status.exitstatus != 0
            raise CommandReturnError.new("Command failed (return #{status.exitstatus}).")
          end
        rescue Exception => e
          msg = strip_credential(e.message)
          # The command failed, log it and re-raise
          logmsg = "Command failed: #{msg}"
          logmsg << "\n"
          logmsg << "    >> #{strip_credential(cmd)}"
          if e.is_a? CommandReturnError
            raise CommandReturnError.new(logmsg)
          else
            raise CommandExceptionError.new(logmsg)
          end
        ensure
          [stdin, stdout, stderr].each {|io| io.close unless io.closed?}
        end
        result
      end

    else

      def popen3(*cmd, &block)
        if Hash === cmd.last
          options = cmd.pop.dup
        else
          options = {}
        end

        result = nil
        stdin, stdout, stderr, wait_thr = nil
        begin
          if options[:merge_stderr]
            stdin, stdout, wait_thr = Open3.popen2e(*cmd)
          else
            stdin, stdout, stderr, wait_thr = Open3.popen3(*cmd)
          end
          if options[:stdout_only]
            stdin.close
            result = block.call(stdout) if block_given?
          elsif options[:merge_stderr]
            result = block.call(stdin, stdout) if block_given?
          else
            result = block.call(stdin, stdout, stderr) if block_given?
          end
          wait_thr.join
          if (options[:check_return] and
              wait_thr and wait_thr.value and
              wait_thr.value.exitstatus != 0)
            raise CommandReturnError.new("Command failed (return #{wait_thr.value.exitstatus}).")
          end
        rescue Exception => e
          msg = strip_credential(e.message)
          # The command failed, log it and re-raise
          logmsg = "Command failed: #{msg}"
          logmsg << "\n"
          logmsg << "    >> #{strip_credential(cmd)}"
          if e.is_a? CommandReturnError
            raise CommandReturnError.new(logmsg)
          else
            raise CommandExceptionError.new(logmsg)
          end
        ensure
          [stdin, stdout, stderr].each {|io| io.close if io and not io.closed?}
        end
        result
      end
    end

    def strip_credential(message)
      message
    end

    def get_gistore_tasks(options={})
      cmds = [git_cmd, "config"]
      unless ENV["GISTORE_TEST_GIT_CONFIG"]
        if options[:system]
          cmds << "--system"
        elsif options[:global]
          cmds << "--global"
        end
      end
      cmds << "--get-regexp"
      cmds << "gistore.task."
      cmds << {:with_git_config => true} if ENV["GISTORE_TEST_GIT_CONFIG"]
      tasks = {}
      begin
        Gistore::shellout(*cmds) do |stdout|
          stdout.readlines.each do |line|
            if line =~ /^gistore.task.([\S]+) (.*)$/
              tasks[Regexp.last_match(1)] = Regexp.last_match(2)
            end
          end
        end
        tasks
      rescue
        {}
      end
    end

    def is_git_repo?(name)
      File.directory?("#{name}/objects") &&
      File.directory?("#{name}/refs") &&
      File.exist?("#{name}/config")
    end
  end

  def git_cmd; self.class.git_cmd; end

  def git_version; self.class.git_version; end

  def git_version_compare(version)
    self.class.git_version_compare(version)
  end

  class Tty
    class << self
      def options
        @options ||= {}
      end
      def blue; bold 34; end
      def white; bold 39; end
      def red; underline 31; end
      def yellow; underline 33 ; end
      def reset; escape 0; end
      def em; underline 39; end
      def green; color 92 end
      def gray; bold 30 end

      def width
        @width = begin
          w = %x{stty size 2>/dev/null}.chomp.split.last.to_i.nonzero?
          w ||= %x{tput cols 2>/dev/null}.to_i
          w < 1 ? 80 : w
        end
      end

      def truncate(str)
        str.to_s[0, width - 4]
      end

      def die(message)
        error message
        exit 1
      end

      def error(message)
        lines = message.to_s.split("\n")
        if STDERR.tty?
          STDERR.puts "#{Tty.red}Error#{Tty.reset}: #{lines.shift}"
        else
          STDERR.puts "Error: #{lines.shift}"
        end
        STDERR.puts lines unless lines.empty?
      end

      def warning(message)
        if STDERR.tty?
          STDERR.puts "#{Tty.red}Warning#{Tty.reset}: #{message}"
        else
          STDERR.puts "Warning: #{message}"
        end
      end

      def info(message)
        unless quiet?
          if STDERR.tty?
            STDERR.puts "#{Tty.blue}Info#{Tty.reset}: #{message}"
          else
            STDERR.puts "Info: #{message}"
          end
        end
      end

      def debug(message)
        if verbose?
          if STDERR.tty?
            STDERR.puts "#{Tty.yellow}Debug#{Tty.reset}: #{message}"
          else
            STDERR.puts "Debug: #{message}"
          end
        end
      end

      private

      def verbose?
        options[:verbose]
      end

      def quiet?
        options[:quiet]
      end

      def color n
        escape "0;#{n}"
      end
      def bold n
        escape "1;#{n}"
      end
      def underline n
        escape "4;#{n}"
      end
      def escape n
        "\033[#{n}m" if $stdout.tty?
      end

      public

      def show_columns(args)
        if Hash === args.last
          options = args.last.dup
        else
          options = {}
        end
        options[:padding] ||= 4
        options[:indent] ||= 4
        output = ''

        if $stdout.tty?
          # determine the best width to display for different console sizes
          console_width = width
          longest = args.sort_by { |arg| arg.length }.last.length rescue 0
          optimal_col_width = ((console_width - options[:indent] + options[:padding]).to_f /
                               (longest + options[:padding]).to_f).floor rescue 0
          cols = optimal_col_width > 1 ? optimal_col_width : 1

          Gistore::shellpipe("/usr/bin/pr",
                             "-#{cols}",
                             "-o#{options[:indent]}",
                             "-t",
                             "-w#{console_width}") do |stdin, stdout, stderr|
            stdin.puts args
            stdin.close
            output << stdout.read
          end
          output.rstrip!
          output << "\n" unless output.empty?
        else
          output << args.map{|e| " " * options[:indent] + e.to_s}  * "\n"
        end
        output
      end
    end
  end
end

def git_cmd
  Gistore.git_cmd
end

class String
  def charat(n)
    result = self.send "[]", n
    RUBY_VERSION < "1.9" ?  result.chr : result
  end
end
