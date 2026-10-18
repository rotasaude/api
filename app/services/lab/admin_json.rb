# Formas do admin do laboratório (contrato §3; dashboard D12).
module Lab
  module AdminJson
    ANALYTE_TEMPLATE = %w[key name loinc unit value_type choices decimals reference_ranges].freeze

    module_function

    def template(t)
      { id: t.id, sigtap_code: t.sigtap_code, name: t.name, sector: t.sector, material: t.material, container: t.container,
        suggested_method: t.suggested_method, preparation: t.preparation,
        analytes: t.analytes.map { |a| a.attributes.slice(*ANALYTE_TEMPLATE) } }
    end

    def version(v)
      { id: v.id, version: v.version, method: v.analysis_method, material: v.material, container: v.container,
        instrument_test_code: v.instrument_test_code, lab_instrument_id: v.lab_instrument_id, analytes: v.analytes,
        created_by: Screenings::Json.staff_name(v.created_by_user), created_at: v.created_at.iso8601 }
    end

    def exam(e, versions: false)
      body = { id: e.id, provider_id: e.exam_provider_id, template_id: e.lab_exam_template_id, sigtap_code: e.sigtap_code, name: e.name,
               sector: e.sector, bench: e.bench, delivery_days: e.delivery_days, active: e.active,
               current_version: e.current_version && version(e.current_version) }
      if versions
        body[:versions] = e.versions.includes(:created_by_user).map do |v|
          { id: v.id, version: v.version, created_at: v.created_at.iso8601, created_by: Screenings::Json.staff_name(v.created_by_user) }
        end
      end
      body
    end

    def releaser(r)
      professional = r.user.professional
      { id: r.id, user_id: r.user_id, name: Screenings::Json.staff_name(r.user), email: r.user.email_address,
        provider_id: r.exam_provider_id, council: professional&.council, council_uf: professional&.council_state,
        council_number: professional&.registration_number, technical_lead: r.technical_lead, technical_deputy: r.technical_deputy }
    end

    def instrument(i)
      { id: i.id, provider_id: i.exam_provider_id, name: i.name, manufacturer: i.manufacturer, model: i.model,
        serial_number: i.serial_number, sector: i.sector, hl7_equipment_id: i.hl7_equipment_id, active: i.active }
    end

    def reason(r) = { id: r.id, provider_id: r.exam_provider_id, name: r.name, active: r.active }
  end
end
