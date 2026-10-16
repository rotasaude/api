# Críticos (contrato §5; dashboard D10/D11). A lista mostra paciente e
# componente (sem valor) e grava trilha; o contador, não (é a única rota lida
# em intervalo) e devolve só { count }. Escopo: laboratórios do usuário.
module Lab
  class CriticalsController < BaseController
    GRANT = ClinicalRecord::Access::Grant.new(kind: :lab_report, opening: nil, reason: nil)

    before_action { forbid if provider_ids.empty? }

    def create
      result = Lab::RecordCriticalNotice.call(result_id: params[:result_id], notified_person: params[:notified_person],
                                              notified_role: params[:notified_role], channel: params[:channel],
                                              notified_at: params[:notified_at], by: Current.user)
      return render_failure(result) if result.failure?

      render json: { id: result.payload[:notice].id }, status: :created
    end

    def index
      after = Exams::Cursor.decode(params[:after])
      rows, next_after = Lab::Criticals.page(provider_ids: provider_ids, after: after, limit: Timeline::Query.limit(params[:limit]))
      ActiveRecord::Associations::Preloader.new(records: rows, associations: { lab_requisition_item: [ { lab_requisition: :patient },
                                                                                                         { lab_exam_version: :lab_exam } ] }).call
      rows.map { |row| row.lab_requisition_item.lab_requisition }.uniq.each do |req|
        ClinicalRecord::Trail.viewed!(patient: req.patient, user: Current.user, grant: GRANT, extra: { lab_requisition_id: req.id })
      end
      render json: { criticals: rows.map { |row| critical_json(row) }, next_after: next_after }
    rescue Exams::Cursor::Invalid
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    end

    def count = render(json: { count: unnotified.count })

    private

    def provider_ids = (@provider_ids ||= Lab::Access.provider_ids(Current.user))
    def unnotified = Lab::Criticals.unnotified(provider_ids: provider_ids)

    def critical_json(row)
      item = row.lab_requisition_item
      req = item.lab_requisition
      { result_id: row.id, requisition_id: req.id, requisition_number: req.number, patient_display_name: req.patient.display_name,
        analyte_name: item.lab_exam_version.analyte(row.analyte_key)&.fetch("name"), flag: row.flag,
        released_at: row.anchor_released_at.iso8601 }
    end
  end
end
