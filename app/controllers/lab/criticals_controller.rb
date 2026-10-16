# Críticos (contrato §5; dashboard D10/D11). A lista mostra paciente e
# componente (sem valor) e grava trilha; o contador, não (é a única rota lida
# em intervalo) e devolve só { count }. Escopo: laboratórios do usuário.
module Lab
  class CriticalsController < BaseController
    GRANT = ClinicalRecord::Access::Grant.new(kind: :lab_report, opening: nil, reason: nil)

    before_action { forbid if Lab::Access.provider_ids(Current.user).empty? }

    def create
      result = Lab::RecordCriticalNotice.call(result_id: params[:result_id], notified_person: params[:notified_person],
                                              notified_role: params[:notified_role], channel: params[:channel],
                                              notified_at: params[:notified_at], by: Current.user)
      return render_failure(result) if result.failure?

      render json: { id: result.payload[:notice].id }, status: :created
    end

    def index
      rows = unnotified.preload(lab_requisition_item: [ { lab_requisition: %i[patient reports] }, { lab_exam_version: :lab_exam } ])
                       .order(:entered_at, :id).to_a
      rows.map { |row| row.lab_requisition_item.lab_requisition }.uniq.each do |req|
        ClinicalRecord::Trail.viewed!(patient: req.patient, user: Current.user, grant: GRANT, extra: { lab_requisition_id: req.id })
      end
      render json: { criticals: rows.map { |row| critical_json(row) } }
    end

    def count = render(json: { count: unnotified.count })

    private

    def unnotified = Lab::Criticals.unnotified(provider_ids: Lab::Access.provider_ids(Current.user))

    def critical_json(row)
      item = row.lab_requisition_item
      req = item.lab_requisition
      { result_id: row.id, requisition_id: req.id, requisition_number: req.number, patient_display_name: req.patient.display_name,
        analyte_name: item.lab_exam_version.analyte(row.analyte_key)&.fetch("name"), flag: row.flag,
        released_at: req.reports.select { |r| r.status == "released" }.filter_map(&:released_at).max&.iso8601 }
    end
  end
end
