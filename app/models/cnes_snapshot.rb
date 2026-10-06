# Retrato do CNES de um município numa competência (ADR 0028; spec 2026-10-05
# §5). Escrito só por Cnes::SnapshotWriter.
class CnesSnapshot < PlatformRecord
  RETENTION = 13

  has_many :establishments, class_name: "CnesEstablishment", foreign_key: :snapshot_id, inverse_of: false
  has_many :teams, class_name: "CnesTeam", foreign_key: :snapshot_id, inverse_of: false
  has_many :bonds, class_name: "CnesProfessionalBond", foreign_key: :snapshot_id, inverse_of: false
end
