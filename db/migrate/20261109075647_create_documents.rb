class CreateDocuments < ActiveRecord::Migration[8.1]
def change
  create_table :documents do |t|
    t.string :title, null: false
    t.string :source_path, null: false
    t.string :url
    t.text :content, null: false
    t.timestamps
  end
  add_index :documents, :source_path, unique: true
end
end
