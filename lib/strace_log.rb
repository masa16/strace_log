require 'strscan'
require 'pathname'
require 'csv'

module StraceLog

  VERSION = "0.1.3"

  class ParsedCall
    ESCAPES = [ /x[\da-f][\da-f]/i, /n/, /t/, /r/, /\\/, /"/, /\d+/]

    def initialize(line)
      @size = nil
      if /^(?:(\d\d:\d\d:\d\d|\d+)(?:\.(\d+))? )?[+-]{3}.*[+-]{3}$/ =~ line
        @mesg = line
      else
        s = StringScanner.new(line)
        s.scan(/^(?:(\d\d:\d\d:\d\d|\d+)(?:\.(\d+))? )?([\w\d]+)\(/)
        @time = s[1]
        @usec = s[2]
        @func = s[3]
        @args = scan_items(s,/\s*\)\s*/)
        s.scan(/\s*= ([^=<>\s]+(?:<[^<>]*>)?)(?:\s+([^<>]+))?(?: <([\d.]+)>)?$/)
        @ret  = s[1]
        @mesg = s[2]
        @elap = s[3]
      end
    end
    attr_reader :time, :usec, :func, :args, :ret , :mesg, :elap, :size

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

    def set_size
      sz = @ret.to_i
      if sz >= 0
        @size = sz
      end
    end
  end


  class Counter
    def initialize
      @calls = 0
      @errors = 0
      @time = 0
      @size = nil
    end
    attr_reader :calls, :errors, :size, :time

    def count(call)
      @calls += 1
      @errors += 1 if call.ret == "-1"
      @time += call.elap.to_f if call.elap
      @size = (@size||0) + call.size if call.size
    end

    def to_a
      [@calls,@errors,"%.6f"%@time,@size]
    end
  end

  class IOCounter
    def initialize(path)
      @path = path
      @rename = []
      @counter = {}
    end
    attr_reader :path, :rename

    def count(fc)
      c = (@counter[fc.func] ||= Counter.new)
      c.count(fc)
    end

    def rename_as(newpath)
      @rename << @path
      @path = newpath
    end

    def each
      @counter.keys.map do |func|
        yield [@path,func,*@counter[func].to_a]
      end
    end
  end

  class Stat

    def initialize(sum:false,table:'/etc/mtab',column:2)
      @sum = sum
      @stat = {}
      @total = IOCounter.new('*')
      if @sum
        a = open(table,'r').each_line.map do |line|
          line.split(/\s+/)[column-1]
        end.sort.reverse
        @paths = Hash[ a.map{|x| [x, /^#{x.sub(/\/$/,'')}($|\/)/] } ]
      end
    end

    attr_reader :stat, :total

    def parse(a)
      @fd2path = ["stdin", "stdout", "stderr"]
      a.each do |line|
        stat_call( ParsedCall.new(line) )
      end
    end

    def get_fd(arg)
      if /([-\d]+)(<.*>)?/ =~ arg
        x = $1.to_i
        return x
      else
        raise
      end
    end

    def stat_call(pc)
      path = nil

      case pc.func

      when /^(execve|l?stat|(read|un)?link|getc?wd|access|mkdir|mknod|chmod|chown)$/
        path = pc.args[0]

      when /^open$/
        path = pc.args[0]
        if pc.ret != "-1"
          fd = pc.ret.to_i
          @fd2path[fd] = path
        end

      when /^connect$/
        fd = get_fd(pc.args[0])
        @fd2path[fd] = path = "socket"

      when /^close$/
        fd = get_fd(pc.args[0])
        path = @fd2path[fd]
        if pc.ret != "-1"
          @fd2path[fd] = nil
        end

      when /^(readv?|writev?)$/
        pc.set_size
        fd = get_fd(pc.args[0])
        path = @fd2path[fd]

      when /^(fstat|fchmod|[fl]chown|lseek|ioctl|fcntl|getdents|sendto|recvmsg)$/
        fd = get_fd(pc.args[0])
        path = @fd2path[fd]

      when /^rename$/
        rename(pc)
        path = pc.args[1]

      when /^dup[23]?$/
        fd = get_fd(pc.args[0])
        path = @fd2path[fd]
        if pc.ret != "-1"
          fd2 = pc.ret.to_i
          @fd2path[fd2] = @fd2path[fd]
        end

      when /^mmap$/
        fd = get_fd(pc.args[4])
        path = @fd2path[fd] if fd >= 0

      when NilClass
        return
      end

      @total.count(pc)

      if path
        if @sum
          realpath = File.exist?(path) ? Pathname.new(path).realdirpath.to_s : path
          @paths.each do |mp,re|
            if re =~ realpath
              (@stat[mp] ||= IOCounter.new(mp)).count(pc)
              return
            end
          end
        end
        (@stat[path] ||= IOCounter.new(path)).count(pc)
      end
    end

    def rename(pc)
      if pc.ret != "-1"
        oldpath = pc.args[0]
        newpath = pc.args[1]
        ioc = @stat[newpath] = (@stat[oldpath] ||= IOCounter.new(oldpath))
        ioc.rename_as(newpath)
        @stat.delete(oldpath)
      end
    end

    def write(file=nil)
      block = proc do |w|
        w << ["path","syscall","calls","errors","time","size"]
        @total.each{|item| w << item}
        @stat.each do |path,cntr|
          cntr.each{|item| w << item}
        end
      end
      if file
        CSV.open(file,'w',&block)
      else
        CSV.instance(&block)
      end
    end

  end
end
