# Abre a requisição (contrato §4; spec §5.1). Quem: lab_staff (posto do
# laboratório, `lab`) ou profissional com vínculo na UBS de origem que coleta
# (`ubs`). Exames do 21a do paciente (awaiting_schedule/scheduled, sem item),
# mais pedidos em papel (viram exam_order lab_reception). Numa transação:
# número, amostras (uma por material/recipiente da versão vigente), itens e,
# no 21a, `scheduled` no laboratório. O índice único de exam_order_id fecha
# a corrida de duas requisições com o mesmo exame.
module Lab
  module OpenRequisition
    MAX_ORDERS = 30

    module_function

    def call(params, by:, now: Time.current)
      p = params.to_h.stringify_keys
      provider = p["provider_id"].is_a?(String) && Access.labs.find_by(id: p["provider_id"])
      return Result.fail(:invalid_provider) unless provider

      unit = p["origin_unit_id"].is_a?(String) && HealthUnit.find_by(id: p["origin_unit_id"], active: true)
      return Result.fail(:not_found) unless unit

      place = p["collection_place"]
      return Result.fail(:invalid_collection_place) unless LabRequisition::PLACES.include?(place)

      allowed = authorize(by, provider, unit, place)
      return allowed if allowed.is_a?(Result)

      patient = p["patient_id"].is_a?(String) && Patient.find_by(id: p["patient_id"])
      return Result.fail(:not_found) unless patient
      return Result.fail(:biological_sex_required) unless LabRequisition::SEXES.include?(p["biological_sex"])

      mother = p["mother_name"].is_a?(String) ? p["mother_name"].strip : ""
      return Result.fail(:mother_name_required) unless mother.length.between?(1, 120)

      info = p["clinical_info"].is_a?(String) ? p["clinical_info"].strip.presence : nil
      return Result.fail(:invalid_clinical_info) if info && info.length > 1000
      return Result.fail(:invalid_urgent) unless [ true, false ].include?(p.fetch("urgent", false))

      ids = Array(p["exam_order_ids"])
      papers = Array(p["paper_orders"])
      return Result.fail(:invalid_orders) if (ids.empty? && papers.empty?) || ids.size + papers.size > MAX_ORDERS
      return Result.fail(:invalid_orders) unless ids.all? { |id| id.is_a?(String) && id.match?(Exams::BaseController::UUID) }

      exams = LabExam.where(exam_provider_id: provider.id, active: true).where.not(current_version_id: nil).includes(:current_version)
                     .index_by(&:sigtap_code)
      paper_specs = papers.map { |paper| paper_spec(paper, exams) }
      failed = paper_specs.find { |spec| spec.is_a?(Result) }
      return failed if failed

      result = nil
      ApplicationRecord.transaction do
        orders = ExamOrder.lock.where(id: ids, patient_id: patient.id).order(:id).to_a
        next result = Result.fail(:order_not_eligible) unless orders.size == ids.uniq.size && orders.all? { |o| eligible?(o) }
        next result = Result.fail(:exam_not_in_lab_catalog) unless orders.all? { |o| exams.key?(o.sigtap_code) }

        paper_specs.each do |spec|
          opened = Exams::Open.call(patient: patient, sigtap_code: spec[:sigtap_code], priority: p["urgent"] ? "urgent" : "routine",
                                    unit: unit, origin: "lab_reception", created_by: by, requester_user: spec[:user],
                                    requester_name: spec[:name], requester_cns: spec[:cns], require_catalog: false, now: now)
          raise ActiveRecord::Rollback if opened.failure? && (result = opened)

          orders << opened.payload[:order]
        end
        requisition = build!(provider, unit, patient, place, p, mother, info, orders, exams, by, now)
        DomainEvents.publish("lab_requisition.opened", lab_requisition_id: requisition.id, collection_place: place, urgent: requisition.urgent)
        result = Result.ok(requisition: requisition)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:order_not_eligible)
    end

    def authorize(user, provider, unit, place)
      if place == "lab"
        return Result.fail(:missing_role) unless Access.staff?(user) && Access.member?(user, provider.id)
      else
        return Result.fail(:unit_does_not_collect) unless unit.collects_samples
        return Result.fail(:missing_role) unless Access.collecting_unit_ids(user).include?(unit.id)
      end
      true
    end

    def eligible?(order)
      %w[awaiting_schedule scheduled].include?(order.status) && !LabRequisitionItem.exists?(exam_order_id: order.id)
    end

    # { sigtap_code, requester: { user_id } | { name, cns } } → spec ou falha.
    def paper_spec(raw, exams)
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.stringify_keys : (raw.is_a?(Hash) ? raw.stringify_keys : {})
      return Result.fail(:exam_not_in_lab_catalog) unless exams.key?(raw["sigtap_code"])

      item = ExamCatalogItem.find_by(sigtap_code: raw["sigtap_code"], active: true)
      return Result.fail(:order_not_eligible) if item&.requires_authorization

      requester = raw["requester"].is_a?(Hash) ? raw["requester"].stringify_keys : {}
      if requester["user_id"]
        user = User.find_by(id: requester["user_id"], deactivated_at: nil)
        return Result.fail(:invalid_requester) unless user&.has_role?("health_professional")

        { sigtap_code: raw["sigtap_code"], user: user }
      else
        name = requester["name"].is_a?(String) ? requester["name"].strip : ""
        return Result.fail(:invalid_requester) unless name.length.between?(1, 120)
        return Result.fail(:invalid_cns) unless Professionals::Cns.valid?(requester["cns"].to_s)

        { sigtap_code: raw["sigtap_code"], name: name, cns: requester["cns"].to_s }
      end
    end

    def build!(provider, unit, patient, place, p, mother, info, orders, exams, by, now)
      days = orders.map { |o| exams.fetch(o.sigtap_code).delivery_days }.max
      requisition = LabRequisition.create!(number: LabRequisition.next_number, patient: patient, exam_provider: provider, origin_unit: unit,
                                           collection_place: place, biological_sex: p["biological_sex"], mother_name: mother,
                                           urgent: p.fetch("urgent", false), clinical_info: info,
                                           expected_delivery_on: now.in_time_zone.to_date + days, opened_by_user: by)
      groups = orders.group_by { |o| v = exams.fetch(o.sigtap_code).current_version; [ v.material, v.container ] }
      raise ArgumentError, "amostras demais" if groups.size > LabSample::MAX_PER_REQUISITION

      place_text = place == "lab" ? "#{provider.name} — coleta no laboratório" : "#{unit.name} — coleta na unidade"
      groups.each_with_index do |((material, container), group), index|
        sample = LabSample.create!(lab_requisition: requisition, barcode: LabSample.barcode_for(requisition.number, index + 1),
                                   material: material, container: container)
        group.each do |order|
          LabRequisitionItem.create!(lab_requisition: requisition, exam_order: order, lab_exam_version: exams.fetch(order.sigtap_code).current_version,
                                     lab_sample: sample)
          moved = Exams::Transition.call(order: order, kind: "scheduled", actor_user: by, now: now,
                                         changes: { exam_provider_id: provider.id, scheduled_at: now, scheduled_place: place_text })
          raise ActiveRecord::RecordNotUnique, "transição recusada" if moved.failure?
        end
      end
      requisition
    end
    private_class_method :authorize, :eligible?, :paper_spec, :build!
  end
end

