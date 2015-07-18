require 'strscan'

module StraceLog

  VERSION = "0.1.1"

  class ParsedCall
    ESCAPES = [ /x[\da-f][\da-f]/i, /n/, /t/, /r/, /\\/, /"/, /\d+/]

    def initialize(line)
      if /^---.*---$/ =~ line
        @mesg = line
      else
        s = StringScanner.new(line)
        s.scan(/^(?:(\d\d:\d\d:\d\d|\d+)(?:\.(\d+))? )?([\w\d]+)\(/)
        @time = s[1]
        @usec = s[2]
        @func = s[3]
        @args = scan_items(s,/\s*\)\s*/)
        s.scan(/\s*= ([^=<>\s]+)(?:\s+([^<>]+))?(?: <([\d.]+)>)?$/)
        @ret  = s[1]
        @mesg = s[2]
        @elap = s[3]
      end
    end
    attr_reader :time, :usec, :func, :args, :ret , :mesg, :elap

    def scan_items(s,close)
      args = []
      i = 0
      while !s.scan(close)
        x = scan_string(s) || scan_bracket(s) ||
          scan_brace(s) || scan_method(s) || scan_other(s)
        if x.nil?
          raise "match error: args=#{args.inspect} post_match=#{s.post_match}"
        end
        (args[i] ||= "") << x
        if s.scan(/\s*,\s*/)
          i += 1
        end
      end
      args
    end

    def scan_string(s)
      return nil if s.scan(/\s*"/).nil?
      arg = ""
      while !s.scan(/"/)
        if s.scan(/\\/)
          ESCAPES.each do |re|
            if x = s.scan(re)
              arg << eval('"\\'+x+'"')
              break
            end
          end
        elsif x = s.scan(/[^\\"]+/)
          arg << x
        end
      end
      if x = s.scan(/\.+/)
        arg << x
      end
      arg
    end

    def scan_bracket(s)
      s.scan(/\s*\[\s*/) && '['+scan_items(s,/\s*\]\s*/).join(',')+']'
    end

    def scan_brace(s)
      s.scan(/\s*{\s*/) && '{'+scan_items(s,/\s*}\s*/).join(',')+'}'
    end

    def scan_method(s)
      if s.scan(/([^"\\,{}()\[\]]+)\(/)
        meth = s[1]
        meth+'('+scan_items(s,/\s*\)\s*/).join(',')+')'
      end
    end

    def scan_other(s)
      s.scan(/[^"\\,{}()\[\]]+/)
    end
  end


  class IOCounter
    def initialize(path)
      @path = path
      @ok   = {}
      @fail = {}
      @size = {}
      @time = {}
      @rename = []
    end
    attr_reader :path, :ok, :fail, :size, :time, :rename

    def add(h,func,c)
      h[func] = (h[func] || 0) + c
    end

    def count(fc)
      if fc.ret == "-1"
        add(@fail, fc.func, 1)
      else
        add(@ok, fc.func, 1)
      end
      add(@time, fc.func, fc.elap.to_f) if fc.elap
    end

    def count_size(fc)
      sz = fc.ret.to_i
      if sz >= 0
        add(@size, fc.func, sz)
      end
      count(fc)
    end

    def rename_as(newpath)
      @rename << @path
      @path = newpath
    end

    def print
      Kernel.print @path+":\n"
      if !@ok.empty?
        keys = @ok.keys.sort
        Kernel.print " ok={"+keys.map{|k| "#{k}:#{@ok[k]}"}.join(", ")+"}\n"
      end
      if !@fail.empty?
        keys = @fail.keys.sort
        Kernel.print " fail={"+keys.map{|k| "#{k}:#{@fail[k]}"}.join(", ")+"}\n"
      end
      if !@size.empty?
        keys = @size.keys.sort
        Kernel.print " size={"+keys.map{|k| "#{k}:#{@size[k]}"}.join(", ")+"}\n"
      end
      if !@time.empty?
        keys = @time.keys.sort
        Kernel.print " time={"+keys.map{|k| "#{k}:#{@time[k]}"}.join(", ")+"}\n"
      end
      if !@rename.empty?
        Kernel.print " rename={#{@rename.join(', ')}}\n"
      end
      puts
    end
  end


  class Stat

    def initialize
      @stat = {}
      @count = {}
      @spent = {}
    end

    attr_reader :stat, :count, :spent

    def parse(a)
      @fd2path = ["stdin", "stdout", "stderr"]
      a.each do |line|
        stat_call( ParsedCall.new(line) )
      end
    end

    def stat_call(pc)
      m = pc.func
      return if m.nil?
      @count[m] = (@count[m] || 0) + 1
      @spent[m] = (@spent[m] || 0) + pc.elap.to_f if pc.elap

      case m

      when /^(open|execve|l?stat|(read|un)?link|getc?wd|access|mkdir|mknod|chmod|chown)$/
        path = pc.args[0]
        count_path(path,pc)
        if m=="open" && pc.ret != "-1"
          fd = pc.ret.to_i
          @fd2path[fd] = path
        end

      when /^(readv?|writev?)$/
        path = @fd2path[pc.args[0].to_i]
        count_size(path,pc)

      when /^(fstat|fchmod|[fl]chown|lseek|ioctl|fcntl|getdents|sendto|recvmsg|close)$/
        fd = pc.args[0].to_i
        count_fd(fd,pc)
        if m=="close" && pc.ret != "-1"
          @fd2path[fd] = nil
        end

      when /^rename$/
        path = pc.args[0]
        count_path(path,pc)
        rename(pc)

      when /^dup[23]?$/
        fd = pc.args[0].to_i
        count_fd(fd,pc)
        if pc.ret != "-1"
          fd = pc.ret.to_i
          @fd2path[fd] = path
        end

      when /^mmap$/
        fd = pc.args[4].to_i
        if fd >= 0
          count_fd(fd,pc)
        end

      when /^connect$/
        fd = pc.args[0].to_i
        @fd2path[fd] = path = pc.args[1]
        count_path(path,pc)

      end
    end

    def count_fd(fd,pc)
      path = @fd2path[fd]
      count_path(path,pc)
    end

    def count_path(path,pc)
      io_counter(path).count(pc)
    end

    def count_size(path,pc)
      io_counter(path).count_size(pc)
    end

    def io_counter(path)
      @stat[path] ||= IOCounter.new(path)
    end

    def rename(pc)
      if pc.ret != "-1"
        oldpath = pc.args[0]
        newpath = pc.args[1]
        ioc = @stat[newpath] = @stat[oldpath]
        ioc.rename_as(newpath)
        @stat.delete(oldpath)
      end
    end

    def print
      Kernel.print "count={\n"
      @count.each do |m,c|
        Kernel.print " #{m}: #{c},\n"
      end
      Kernel.print "}\n\n"
      Kernel.print "time={\n"
      @spent.each do |m,t|
        Kernel.print " #{m}: #{t},\n"
      end
      Kernel.print "}\n\n"
      files = @stat.keys.select{|x| x.class==String}.sort
      files.each do |fn|
        @stat[fn].print
      end
    end

  end
end
