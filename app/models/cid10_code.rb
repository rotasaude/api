# app/models/cid10_code.rb
class Cid10Code < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
