class AddContainmentPathToResourceStatuses < ActiveRecord::Migration[4.2]
  def change
    add_column :resource_statuses, :containment_path, :text
  end
end
