module Rag
  # Turns the sections of ONE document into chunks.
  # Positions are per document (matches a unique [document_id, position] index).
  class Chunker
    MAX_BLOCK_CHARS = 3000
    MAX_CHARS = 1500
    MIN_CHARS = 200
    SEPARATOR = " > "
    FENCE     = /\A\s*(```|~~~)/
    FENCE_LINE      = /^\s*(```|~~~)/

    Chunk = Struct.new(:heading_path, :text, :position, keyword_init: true)

    def self.call(sections, **opts) = new(**opts).call(sections)

    def initialize(max_chars: MAX_CHARS, min_chars: MIN_CHARS, max_block_chars: MAX_BLOCK_CHARS)
      @max       = max_chars
      @min       = min_chars
      @max_block = max_block_chars
    end

    def call(sections)
      pieces = sections.flat_map { split_section(_1) }
      merge_short(pieces).each_with_index.map do |(path, text), i|
        Chunk.new(heading_path: path, text: text, position: i)
      end
    end

    private

    # Returns [[heading_path, text], ...]
    def split_section(section)
      return [ [ section.heading_path, section.text ] ] if section.text.size <= @max

      blocks = glue_lead_ins(split_blocks(section.text))
      blocks = blocks.flat_map { oversized?(_1) ? split_by_lines(_1) : [ _1 ] }
      pack(blocks).map { [ section.heading_path, _1 ] }
    end

    # Blocks are separated by blank lines, except blank lines inside code fences.
    # A table is just consecutive lines, so it stays in one block.
    def split_blocks(text)
      blocks  = []
      current = []
      fence   = nil

      text.each_line(chomp: true) do |line|
        if fence
          fence = nil if line.strip.start_with?(fence)
          current << line
        elsif (m = line.match(FENCE))
          fence = m[1]
          current << line
        elsif line.strip.empty?
          blocks << current.join("\n") unless current.empty?
          current = []
        else
          current << line
        end
      end

      blocks << current.join("\n") unless current.empty?
      blocks
    end

    # A block ending with ":" introduces the next block (table, code, list),
    # so keep them together.
    def glue_lead_ins(blocks)
      blocks.each_with_object([]) do |block, out|
        if out.last&.end_with?(":")
          out[-1] = "#{out.last}\n\n#{block}"
        else
          out << block
        end
      end
    end

    # Fallback for a single block larger than @max. Known limitation:
    # this can cut a code fence in half.
    def split_by_lines(block)
      parts   = []
      current = +""

      block.each_line do |line|
        if !current.empty? && current.size + line.size > @max
          parts << current.rstrip
          current = +""
        end
        current << line
      end

      parts << current.rstrip unless current.empty?
      parts
    end

    # Blocks with a code fence get a higher limit so code is not cut in half.
    def oversized?(block)
      limit = block.match?(FENCE_LINE) ? @max_block : @max
      block.size > limit
    end

    # Greedy: add blocks until the next one would exceed @max.
    def pack(blocks)
      chunks  = []
      current = nil

      blocks.each do |block|
        if current && current.size + 2 + block.size <= @max
          current << "\n\n" << block
        else
          chunks << current if current
          current = block.dup
        end
      end

      chunks << current if current
      chunks
    end

    # Merge a short piece into the previous one when both share the same
    # parent heading. The merged section's title is kept in the text,
    # because heading titles are not part of section text.
    def merge_short(pieces)
      pieces.each_with_object([]) do |(path, text), merged|
        prev = merged.last

        if prev && text.size < @min &&
           prev[1].size + text.size + 2 <= @max &&
           parent(prev[0]) == parent(path)
          addition = path == prev[0] ? text : "#{title(path)}\n#{text}"
          prev[1] = "#{prev[1]}\n\n#{addition}"
        else
          merged << [ path, text ]
        end
      end
    end

    def parent(path) = path.split(SEPARATOR)[0...-1]
    def title(path)  = path.split(SEPARATOR).last.to_s
  end
end
