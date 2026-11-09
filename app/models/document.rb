class Document < ApplicationRecord
  has_many :chunks, dependent: :destroy

  validates :title, :source_path, :content, presence: true
  validates :source_path, uniqueness: true

  # Title = The line immediately above the first line containing "=====" (Setext, level 1).
  def self.extract_title(content)
    content.lines(chomp: true).each_cons(2) do |text, underline|
      return text.strip if underline.match?(/\A={3,}\s*\z/) && text.strip.present?
    end
    nil
  end
end
