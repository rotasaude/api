# app/models/anvisa_list_substance.rb
class AnvisaListSubstance < PlatformRecord
  KINDS = %w[antimicrobial controlled].freeze

  belongs_to :release, class_name: "AnvisaListRelease", inverse_of: :substances
end
