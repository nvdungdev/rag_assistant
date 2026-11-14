module Rag
  class Retriever
    DISTANCE = "cosine".freeze
    DEFAULT_K = 5

    Result = Struct.new(:chunk, :distance, keyword_init: true)

    def initialize(client: Rag::OllamaClient.new, k: DEFAULT_K)
      @client = client
      @k = Integer(k)
      raise ArgumentError, "k must be positive" unless @k.positive?
    end

    # Returns an Array of Result (closest first) for the given question.
    def call(question)
      question = question.to_s.strip
      raise ArgumentError, "question must not be blank" if question.empty?

      vector = @client.embed([ question ]).first

      Chunk
        .nearest_neighbors(:embedding, vector, distance: DISTANCE)
        .includes(:document)
        .limit(@k)
        .map { |chunk| Result.new(chunk: chunk, distance: chunk.neighbor_distance) }
    end
  end
end
