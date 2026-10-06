# app/models/ciap2_code.rb
class Ciap2Code < PlatformRecord
  belongs_to :release, class_name: "TerminologyRelease"
end
