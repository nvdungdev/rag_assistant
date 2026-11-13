require "net/http"
require "json"

module Rag
  class OllamaClient
    class Error < StandardError; end

    DEFAULT_URL = "http://localhost:11434"
    DEFAULT_MODEL = "bge-m3"
    EXPECTED_DIMENSION = 1024

    def initialize(url: ENV.fetch("OLLAMA_URL", DEFAULT_URL),
                   model: ENV.fetch("OLLAMA_EMBED_MODEL", DEFAULT_MODEL),
                   open_timeout: 5,
                   read_timeout: 300)
      @uri = URI.join(url, "/api/embed")
      @model = model
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Accepts a String or an Array of Strings.
    # Returns an Array of vectors (Array<Array<Float>>), same order as input.
    def embed(texts)
      texts = Array(texts)
      return [] if texts.empty?

      body = post(model: @model, input: texts)
      embeddings = body["embeddings"]
      validate!(embeddings, texts.size)
      embeddings
    end

    private

    def post(payload)
      request = Net::HTTP::Post.new(@uri, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(
        @uri.host, @uri.port,
        use_ssl: @uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Ollama returned #{response.code}: #{response.body.to_s[0, 300]}"
      end

      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Ollama timeout (#{e.class}) at #{@uri}"
    rescue SocketError, SystemCallError => e
      raise Error, "Cannot reach Ollama at #{@uri}: #{e.message}"
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON from Ollama: #{e.message}"
    end

    def validate!(embeddings, expected_count)
      unless embeddings.is_a?(Array) && embeddings.size == expected_count
        raise Error, "Expected #{expected_count} embeddings, got #{embeddings.is_a?(Array) ? embeddings.size : embeddings.class}"
      end

      bad = embeddings.find { |v| !v.is_a?(Array) || v.size != EXPECTED_DIMENSION }
      raise Error, "Unexpected embedding dimension: #{bad.is_a?(Array) ? bad.size : bad.class}" if bad
    end
  end
end
