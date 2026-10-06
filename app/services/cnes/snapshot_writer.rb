# Grava o retrato de um município numa competência (ADR 0028; spec 2026-10-05
# §5): substitui o da mesma competência, insere em lote e poda além das 13
# competências mais recentes. Numa transação (savepoint) da plataforma. O
# insert_all! serializa cada valor pelo tipo do atributo, então CPF e CNS são
# cifrados lá, uma única vez, com a chave da plataforma — aqui vão crus.
module Cnes
  module SnapshotWriter
    BATCH = 1_000

    module_function

    def write!(competence:, ibge_code:, establishments:, teams:, bonds:)
      PlatformRecord.transaction(requires_new: true) do
        CnesSnapshot.where(ibge_code: ibge_code, competence: competence).delete_all
        snapshot = CnesSnapshot.create!(ibge_code: ibge_code, competence: competence, imported_at: Time.current)
        insert(CnesEstablishment, establishments.map { |e| e.slice(:cnes, :name, :unit_type).merge(snapshot_id: snapshot.id) })
        insert(CnesTeam, teams.map { |t| t.slice(:ine, :kind, :cnes, :name, :active).merge(snapshot_id: snapshot.id) })
        insert(CnesProfessionalBond, bonds.map do |b|
          { snapshot_id: snapshot.id, cnes: b[:cnes], ine: b[:ine], cbo_code: b[:cbo_code],
            cpf: b[:cpf], cns: b[:cns] }
        end)
        prune!(ibge_code)
        snapshot
      end
    end

    def insert(model, rows)
      rows.each_slice(BATCH) { |slice| model.insert_all!(slice) }
    end

    def prune!(ibge_code)
      stale = CnesSnapshot.where(ibge_code: ibge_code).order(competence: :desc).offset(CnesSnapshot::RETENTION).pluck(:id)
      CnesSnapshot.where(id: stale).delete_all
    end
  end
end
