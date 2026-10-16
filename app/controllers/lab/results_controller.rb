# Digitação e conferência (contrato §5; dashboard D7). Valor só para quem é
# do laboratório do item; a leitura grava clinical_record.viewed (lab_report).
module Lab
  class ResultsController < BaseController
    GRANT = ClinicalRecord::Access::Grant.new(kind: :lab_report, opening: nil, reason: nil)

    # Por item_id, ou por etiqueta (barcode): com sigtap_code, o formulário
    # completo daquele exame; sem ele (B39), só a lista dos itens da amostra
    # (sem valor) para a bancada escolher. Amostra desconhecida: 404.
    def entry
      by_barcode = !uuid?(params[:item_id]) && params[:barcode].is_a?(String)
      items = load_items(by_barcode)
      return not_found if items.empty?

      req = items.first.lab_requisition
      return forbid unless Lab::Access.member?(Current.user, req.exam_provider_id)

      ClinicalRecord::Trail.viewed!(patient: req.patient, user: Current.user, grant: GRANT, extra: { lab_requisition_id: req.id })
      if by_barcode && !params[:sigtap_code].is_a?(String)
        render json: { items: items.map { |i| Lab::EntryJson.sample_item(i) } }
      else
        render json: { items: items.map { |i| Lab::EntryJson.item(i) } }
      end
    end

    def create
      item = find_item
      return not_found unless item
      return forbid unless Lab::Access.member?(Current.user, item.lab_requisition.exam_provider_id)

      result = Lab::EnterResults.call(item: item, values: params[:values], by: Current.user)
      return render_failure(result) if result.failure?

      version = item.lab_exam_version
      rows = item.results.reload.to_a
      effective = Lab::Effective.ids(item)
      notified = Lab::EntryJson.notified_ids(rows)
      render json: { results: rows.map { |row| Lab::EntryJson.result_row(row, version, notified, effective) } }, status: :created
    end

    def choose
      row = uuid?(params[:id]) && LabResult.find_by(id: params[:id])
      return not_found unless row

      result = Lab::ChooseResult.call(result: row, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Lab::EntryJson.result_row(result.payload[:result]), status: :created
    end

    private

    def load_items(by_barcode)
      scope = LabRequisitionItem.where.not(status: "cancelled")
      scope = if uuid?(params[:item_id]) then scope.where(id: params[:item_id])
              elsif by_barcode then scope.joins(:lab_sample).where(lab_samples: { barcode: params[:barcode] })
              else return []
              end
      if by_barcode && params[:sigtap_code].is_a?(String)
        scope = scope.joins(lab_exam_version: :lab_exam).where(lab_exams: { sigtap_code: params[:sigtap_code] })
      end
      scope.includes(:results, :lab_sample, lab_requisition: :patient, lab_exam_version: :lab_exam).order(:id).to_a
    end

    def find_item
      return LabRequisitionItem.find_by(id: params[:item_id]) if uuid?(params[:item_id])
      return nil unless params[:barcode].is_a?(String) && params[:sigtap_code].is_a?(String)

      LabRequisitionItem.joins(:lab_sample, lab_exam_version: :lab_exam).where.not(status: "cancelled")
                        .find_by(lab_samples: { barcode: params[:barcode] }, lab_exams: { sigtap_code: params[:sigtap_code] })
    end
  end
end
