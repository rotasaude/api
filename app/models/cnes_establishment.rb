class CnesEstablishment < PlatformRecord
  belongs_to :snapshot, class_name: "CnesSnapshot"
end
