# app/models/nursing_protocol_version.rb
class NursingProtocolVersion < ApplicationRecord
  belongs_to :nursing_protocol
  has_many :items, class_name: "NursingProtocolVersionItem", dependent: :restrict_with_exception
end
