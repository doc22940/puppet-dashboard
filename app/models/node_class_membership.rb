class NodeClassMembership < ApplicationRecord
  validates_presence_of :node_id, :node_class_id

  include NodeGroupGraph

  has_parameters

  belongs_to :node
  belongs_to :node_class

  fires :added_to,     :on => :create,  :subject => :node_class, :secondary_subject => :node
  fires :removed_from, :on => :destroy, :subject => :node_class, :secondary_subject => :node
end
