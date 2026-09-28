# JSON do módulo de profissionais (spec §4.1). A lista mascara o CNS e deixa o
# contato de fora; só a ficha (admin) e o "me" trazem tudo.
module ProfessionalRendering
  extend ActiveSupport::Concern

  private

  def profile_json(p, full:)
    json = {
      id: p.id, user_id: p.user_id, email_address: p.user.email_address,
      professional_name: p.professional_name, council: p.council, council_state: p.council_state,
      registration_number: p.registration_number, cns_masked: p.cns_masked
    }
    json.merge!(cns: p.cns, phone: p.phone, contact_email: p.contact_email) if full
    json
  end

  def link_json(l)
    {
      id: l.id, health_unit_id: l.health_unit_id, unit_name: l.health_unit.name, cbo_code: l.cbo_code,
      cbo_title: Professionals::Cbo.find(l.cbo_code)&.title, started_at: l.started_at.iso8601,
      started_by: l.started_by_user.email_address, ended_at: l.ended_at&.iso8601,
      ended_by: l.ended_by_user&.email_address
    }
  end

  def shift_json(s)
    {
      id: s.id, professional_link_id: s.professional_link_id, unit_name: s.professional_link.health_unit.name,
      starts_at: s.starts_at.iso8601, ends_at: s.ends_at.iso8601, cancelled_at: s.cancelled_at&.iso8601,
      cancel_reason: s.cancel_reason
    }
  end

  # Corpo JSON como veio, sem o ParamsWrapper (desligado nos controllers do
  # módulo). Valor não escalar vira nil → recusado; `keys` restringe.
  def scalar_body(keys = nil)
    body = request.request_parameters.to_h
    body = body.slice(*keys) if keys
    body.transform_values { |v| v.is_a?(String) || v.is_a?(Numeric) ? v.to_s : (v.nil? ? nil : :non_scalar) }
  end
end
