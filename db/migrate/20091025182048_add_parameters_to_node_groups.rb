class AddParametersToNodeGroups < ActiveRecord::Migration[4.2]
  def self.up
    add_column :node_groups, :parameters, :text
  end

  def self.down
    remove_column :node_groups, :parameters
  end
end
