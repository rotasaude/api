# Módulo 21a (ADR 0036): cidade com o rastreamento ligado, catálogo,
# prestadores, paciente (par validado → Patients::Resolve), arquivo PDF e um
# pedido aberto pelo caminho real (Exams::Open, Task 7) — até a Task 7 existir,
# exam_order! grava direto.
module ExamHelpers
  PDF_BYTES = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n1 0 obj<<>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".b.freeze
  FAKE_TOKEN = "token-de-teste-do-laboratorio-0123456789abcdef".freeze
  OLD_SIGTAP_COMPETENCE = "200001".freeze

  def exam_city!(record_mode: "record", fhir: false, fake_lab: false, pec: false)
    city = clinical_city!(record_mode: record_mode, enabled: record_mode == "record")
    # Terminologias do 19a: a consulta finalizada (pedido da consulta) avalia
    # problema CIAP-2 e aceita justificativa CID-10.
    ciap2_release!
    cid10_release!
    maintainer = ledi_maintainer!
    Platform::Features.set!(city: city, key: "exam_tracking", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "exam_fhir_inbound", enabled: true, maintainer: maintainer) if fhir || fake_lab
    Platform::Features.set!(city: city, key: "fake_lab", enabled: true, maintainer: maintainer) if fake_lab
    if pec
      Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: maintainer)
      Platform::Features.set!(city: city, key: "pec_external_view", enabled: true, maintainer: maintainer)
      Platform::Features.set!(city: city, key: "exam_pec_bridge", enabled: true, maintainer: maintainer)
    end
    sigtap_release!
    # Terminology::Sigtap.release_for(c) pega a última ativa com versão <= c:
    # sem uma competência antiga, pedido datado no passado (travel_to,
    # competência de mês anterior) não acha SIGTAP. Mesmos códigos.
    sigtap_release!(OLD_SIGTAP_COMPETENCE)
    CityCatalog.reset_cache!
    city
  end

  def exam_catalog_item!(sigtap_code: "0202010503", **attrs)
    ExamCatalogItem.find_by(sigtap_code: sigtap_code) ||
      ExamCatalogItem.create!({ sigtap_code: sigtap_code,
                                result_fields: [ { "key" => "hba1c", "label" => "Hemoglobina glicada", "unit" => "%", "loinc" => "4548-4" } ] }
                              .merge(attrs))
  end

  # items: :all habilita o prestador para todo exame JÁ no catálogo (crie o
  # item antes); items: [] = nenhum (para provar provider_not_enabled_for_exam).
  def exam_provider!(name: "Laboratório Central", token: nil, items: :all, **attrs)
    provider = ExamProvider.create!({ name: name, kind: "municipal" }.merge(attrs))
    provider.update!(fhir_token_digest: ExamProvider.digest(token), fhir_token_rotated_at: Time.current) if token
    (items == :all ? ExamCatalogItem.all : items).each do |item|
      ExamProviderItem.find_or_create_by!(exam_provider: provider, exam_catalog_item: item)
    end
    provider
  end

  # Número único por exemplo para exam_patient! (CPF e telefone saem dele).
  def exam_seq! = (@exam_seq = (@exam_seq || 500) + 1)

  # [paciente, par validado]: o caminho real do paciente (Patients::Resolve).
  # Idade 30..79: o padrão de verified_citizen! (40 + n) daria 541 anos com
  # exam_seq! (501+), e a SIGTAP confere idade mínima/máxima do procedimento.
  def exam_patient!(n, **citizen_attrs)
    citizen = verified_citizen!(n, **{ age: 30 + (n % 50) }.merge(citizen_attrs))
    [ Patients::Resolve.call(citizen).payload.fetch(:patient), citizen ]
  end

  # Equipe ativa da unidade com os usuários (vínculo ativo nela), INE aleatório
  # (exportable_unit! usa um INE fixo e não serve para duas unidades).
  def exam_team!(unit, *users)
    team = HealthTeam.find_by(health_unit: unit) ||
           HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "70",
                              name: "ESF #{unit.name}")
    users.each do |user|
      link = user.professional.links.active.find_by!(health_unit: unit)
      HealthTeamMember.create!(professional: user.professional, health_team: team, cbo_code: link.cbo_code,
                               started_on: Time.zone.today - 30)
    end
    team
  end

  def pdf_file!(user: nil, provider: nil, bytes: PDF_BYTES, content_type: "application/pdf")
    ExamFile.create!(content_type: content_type, byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
                     data: Base64.strict_encode64(bytes), uploaded_by_user: user, exam_provider: provider)
  end

  def exam_order!(patient:, unit:, requester:, sigtap_code: "0202010503", priority: "routine", provider: nil, status: :awaiting_schedule)
    if defined?(Exams::Open) && status == :awaiting_schedule && provider.nil?
      exam_catalog_item!(sigtap_code: sigtap_code)
      result = Exams::Open.call(patient: patient, sigtap_code: sigtap_code, priority: priority, unit: unit, origin: "pec",
                                requester_user: requester, created_by: requester)
      raise "pedido recusado: #{result.reason}" if result.failure?

      return result.payload.fetch(:order)
    end
    ApplicationRecord.transaction do
      order = ExamOrder.create!(patient: patient, sigtap_code: sigtap_code, sigtap_competence: Time.zone.today.strftime("%Y%m"),
                                priority: priority, requester_user: requester, unit: unit, origin: "pec",
                                short_code: ClinicalDocuments::Codes.short_code, status: status.to_s,
                                status_changed_at: Time.current, exam_provider: provider)
      ExamOrderEvent.create!(exam_order: order, kind: "requested", actor_user: requester, occurred_at: Time.current)
      order
    end
  end
end

RSpec.configure { |c| c.include ExamHelpers }
