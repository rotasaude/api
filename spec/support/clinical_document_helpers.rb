# spec/support/clinical_document_helpers.rb
# Módulo 19c (ADR 0033): a cidade com documentos ligados, os papéis, o perfil
# com CNPJ e um documento cru (sem o comando, para as specs de banco).
module ClinicalDocumentHelpers
  def documents_city!(enabled: true)
    city = clinical_city!
    Platform::Features.set!(city: city, key: "clinical_documents", enabled: enabled, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  # O helper de vínculo cria o perfil com CRM; enfermeira e dentista levam o conselho deles.
  def nurse!(unit) = screener!(unit, cbo: "223505").tap { |user| user.professional.update!(council: "COREN") }
  def dentist!(unit) = screener!(unit, cbo: "223208").tap { |user| user.professional.update!(council: "CRO") }

  def city_profile! = CityProfile.current || CityProfile.create!(name: "Cidade de Teste", uf: "PR", ibge_code: "4106902")
  def city_cnpj!(cnpj = "76001234000115") = city_profile!.tap { |profile| profile.update!(cnpj: cnpj) }

  def municipal_admin! = staff_with("admin-doc-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")

  def raw_document!(consultation: nil, attendance: nil, kind: "sick_note", issue_mode: "paper", author: nil,
                    content: { "type" => "leave", "days" => 1, "start_on" => Time.zone.today.iso8601, "cid_authorized" => false })
    attendance ||= consultation.attendance
    ClinicalDocument.create!(kind: kind, patient_id: consultation&.patient_id || attendance.citizen.patient_id,
                             citizen_id: attendance.citizen_id, consultation: consultation, attendance: attendance,
                             author_user_id: (author || consultation.author_user).id, cbo_code: consultation&.cbo_code,
                             issue_mode: issue_mode, verification_token: ClinicalDocuments::Codes.token,
                             short_code: ClinicalDocuments::Codes.short_code, issued_at: Time.current, content: content.to_json)
  end

  # MFA cadastrado (o step-up exige o autenticador).
  def step_up_enrolled!(user)
    Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    user
  end

  # Só em request specs: sessão com step-up recente; PUT/DELETE com corpo JSON
  # (a guarda de escrita por cookie exige Content-Type JSON, inclusive no DELETE).
  def stepped_up!(user) = sign_in_as(step_up_enrolled!(user)).tap { |session| session.update!(mfa_verified_at: Time.current) }
  def json_put(path, params = {}) = put(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })
  def json_delete(path) = delete(path, params: "{}", headers: { "CONTENT_TYPE" => "application/json" })
  def json_body = JSON.parse(response.body)
end

RSpec.configure { |c| c.include ClinicalDocumentHelpers }
