module Rag
  class SectionSplitter
    Section = Struct.new(:heading_path, :text, keyword_init: true)

    ATX    = /\A(\#{1,6})[ \t]+(.+?)[ \t]*\#*[ \t]*\z/
    SETEXT = /\A(={2,}|-{2,})[ \t]*\z/
    FENCE  = /\A\s*(```|~~~)/

    def self.call(markdown) = new(markdown).call

    def initialize(markdown)
      @lines = markdown.lines.map(&:chomp)
    end

    def call
      @sections = []
      @stack    = []
      @buffer   = []
      fence     = nil

      i = 0
      while i < @lines.size
        line = @lines[i]

        if fence
          fence = nil if line.strip.start_with?(fence)
          @buffer << line
          i += 1
        elsif (m = line.match(FENCE))
          fence = m[1]
          @buffer << line
          i += 1
        elsif (m = line.match(ATX))
          start_section(m[1].size, m[2])
          i += 1
        elsif setext_heading?(i)
          level = @lines[i + 1].start_with?("=") ? 1 : 2
          start_section(level, line.strip)
          i += 2
        else
          @buffer << line
          i += 1
        end
      end

      flush
      @sections
    end

    private

    def setext_heading?(i)
      line = @lines[i]
      nxt  = @lines[i + 1]
      return false if line.strip.empty? || nxt.nil? || !nxt.match?(SETEXT)

      i.zero? || @lines[i - 1].strip.empty?
    end

    def start_section(level, title)
      flush
      @stack.pop while @stack.any? && @stack.last[0] >= level
      @stack << [ level, title ]
    end

    def flush
      text = @buffer.join("\n").strip
      @sections << Section.new(heading_path: @stack.map(&:last).join(" > "), text: text) unless text.empty?
      @buffer = []
    end
  end
end
