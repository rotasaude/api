# Requisição (contrato §4): abrir, listar com recorte, ler. A UBS só lê as
# da unidade dela; o laboratório, as dele.
module Lab
  class RequisitionsController < BaseController
    before_action :load_requisition, only: %i[show receipt labels deliver]

    def index
      scope = LabRequisition.includes(:patient, :origin_unit, reports: [ :released_by_user, :pdf_file ])
      ids = Lab::Access.provider_ids(Current.user)
      if ids.any?
        scope = scope.where(exam_provider_id: ids)
        scope = scope.where(exam_provider_id: params[:provider_id]) if params[:provider_id].present?
        scope = scope.where(origin_unit_id: params[:origin_unit_id]) if params[:origin_unit_id].present?
      else
        unit_id = params[:origin_unit_id]
        return render(json: { error: "filter_required" }, status: :unprocessable_entity) unless uuid?(unit_id)
        return forbid("not_unit_staff") unless Exams::Access.unit_staff?(Current.user, unit_id)

        scope = scope.where(origin_unit_id: unit_id)
      end
      statuses = Array(params[:status])
      return render(json: { error: "invalid_filter" }, status: :unprocessable_entity) unless (statuses - LabRequisition::STATUSES).empty?

      scope = scope.where(status: statuses) if statuses.any?
      scope = scope.where(number: params[:number].to_s) if params[:number].present?
      scope = scope.where(id: LabSample.where(barcode: params[:barcode].to_s).select(:lab_requisition_id)) if params[:barcode].present?
      cursor = Exams::Cursor.decode(params[:before])
      scope = scope.where("(lab_requisitions.created_at, lab_requisitions.id) < (?, ?)", *cursor) if cursor
      limit = Timeline::Query.limit(params[:limit])
      rows = scope.order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { requisitions: page.map { |r| Lab::Json.requisition(r, viewer: Current.user, full: false) },
                     next_before: rows.size > limit ? Exams::Cursor.encode(page.last) : nil }
    rescue Exams::Cursor::Invalid
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    end

    def show = render(json: Lab::Json.requisition(@requisition, viewer: Current.user))

    def receipt
      response.headers["Cache-Control"] = "no-store"
      send_data Lab::ReceiptPdf.call(@requisition), type: "application/pdf", disposition: "inline",
                                                    filename: "comprovante-#{@requisition.number}.pdf"
    end

    # Etiquetas (todas, ou as pedidas); toda impressão deixa trilha, com `reprint`.
    # E8: `reprint` lê o payload de `domain_events` (log de trilha usado como
    # estado); uma purga de eventos faz a reimpressão voltar a sair como primeira.
    def labels
      printable = @requisition.samples.where.not(status: %w[rejected not_received])
      if params[:sample_ids].present?
        ids = Array(params[:sample_ids]).uniq
        return not_found unless ids.all? { |id| uuid?(id) } && @requisition.samples.where(id: ids).count == ids.size

        samples = printable.where(id: ids).sort_by { |sample| ids.index(sample.id) }
      else
        samples = printable.to_a
      end
      return render(json: { error: "invalid_samples" }, status: :unprocessable_entity) if samples.empty?

      samples.each do |sample|
        reprint = DomainEvent.where(name: "lab_sample.label_printed").where("payload->>'lab_sample_id' = ?", sample.id).exists?
        DomainEvents.publish("lab_sample.label_printed", lab_sample_id: sample.id, lab_requisition_id: @requisition.id, reprint: reprint)
      end
      response.headers["Cache-Control"] = "no-store"
      send_data Lab::LabelsPdf.call(samples), type: "application/pdf", disposition: "inline", filename: "etiquetas-#{@requisition.number}.pdf"
    end

    def create
      result = Lab::OpenRequisition.call(body_params, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Lab::Json.requisition(result.payload[:requisition].reload, viewer: Current.user), status: :created
    end

    def deliver
      result = Lab::Deliver.call(requisition: @requisition, delivered_to: params[:delivered_to], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Lab::Json.requisition(@requisition.reload, viewer: Current.user)
    end

    private

    def load_requisition
      @requisition = uuid?(params[:id]) && LabRequisition.find_by(id: params[:id])
      return not_found unless @requisition

      readable = Lab::Access.member?(Current.user, @requisition.exam_provider_id) ||
                 Exams::Access.unit_staff?(Current.user, @requisition.origin_unit_id)
      forbid("not_unit_staff") unless readable
    end
  end
end

