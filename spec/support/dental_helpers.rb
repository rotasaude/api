# Módulo 28 (ADR 0046): cidade com o prontuário e a saúde bucal ligados, a
# lista padrão do TSB/ASB (o dump não leva linha), os procedimentos
# odontológicos na SIGTAP de teste, dentista e auxiliar com vínculo, unidade
# CEO com perfil e o caminho até a consulta odontológica. Tudo avaliado só na
# chamada.
module DentalHelpers
  # Nomes da tabela SIGTAP (competência 2026-06, versão 1.1). Os três sem nome
  # na tabela nova (0307010023, 0307010040, 0307030016) são os antigos que os
  # sucessores de restauração substituem (metas do CEO, Task 15).
  SIGTAP = {
    # Desvio 5 (tabela SIGTAP → situação) e o procedimento do dental_body.
    "0307010031" => "RESTAURAÇÃO DE DENTE PERMANENTE ANTERIOR COM RESINA COMPOSTA",
    "0307010074" => "TRATAMENTO RESTAURADOR ATRAUMÁTICO (TRA/ART)",
    "0307010082" => "RESTAURAÇÃO DE DENTE DECÍDUO POSTERIOR COM RESINA COMPOSTA",
    "0307010090" => "RESTAURAÇÃO DE DENTE DECÍDUO POSTERIOR COM AMÁLGAMA",
    "0307010104" => "RESTAURAÇÃO DE DENTE DECÍDUO POSTERIOR COM IONÔMERO DE VIDRO",
    "0307010112" => "RESTAURAÇÃO DE DENTE DECÍDUO ANTERIOR COM RESINA COMPOSTA.",
    "0307010120" => "RESTAURAÇÃO DE DENTE PERMANENTE POSTERIOR COM RESINA COMPOSTA",
    "0307010139" => "RESTAURAÇÃO DE DENTE PERMANENTE POSTERIOR COM AMÁLGAMA",
    "0101020066" => "APLICAÇÃO DE SELANTE (POR DENTE)",
    "0414020120" => "EXODONTIA DE DENTE DECÍDUO",
    "0414020138" => "EXODONTIA DE DENTE PERMANENTE",
    "0307020037" => "TRATAMENTO ENDODÔNTICO DE DENTE DECÍDUO",
    "0307020045" => "TRATAMENTO ENDODÔNTICO DE DENTE PERMANENTE BIRRADICULAR",
    "0307020053" => "TRATAMENTO ENDODÔNTICO DE DENTE PERMANENTE COM TRÊS OU MAIS RAÍZES",
    "0307020061" => "TRATAMENTO ENDODÔNTICO DE DENTE PERMANENTE UNIRRADICULAR",
    "0701070099" => "PROTESE PARCIAL MANDIBULAR REMOVIVEL",
    "0701070102" => "PROTESE PARCIAL MAXILAR REMOVIVEL",
    "0701070110" => "PROTESE TEMPORARIA",
    "0701070129" => "PROTESE TOTAL MANDIBULAR",
    "0701070137" => "PROTESE TOTAL MAXILAR",
    "0701070145" => "PROTESES CORONARIAS / INTRA-RADICULARES FIXAS / ADESIVAS (POR ELEMENTO)",
    "0701070153" => "PRÓTESE DENTÁRIA SOBRE IMPLANTE",
    # Desvio 6: proibido na FAO.
    "0301040079" => "ESCUTA INICIAL / ORIENTAÇÃO (ACOLHIMENTO A DEMANDA ESPONTÂNEA)",
    # Desvio 8 (Valores fixados 4): a lista padrão do TSB/ASB.
    "0101020058" => "APLICAÇÃO DE CARIOSTÁTICO (POR DENTE)",
    "0101020074" => "APLICAÇÃO TÓPICA DE FLÚOR (INDIVIDUAL POR SESSÃO)",
    "0101020082" => "EVIDENCIAÇÃO DE PLACA BACTERIANA",
    "0101020090" => "SELAMENTO PROVISÓRIO DE CAVIDADE DENTÁRIA",
    "0307030059" => "RASPAGEM ALISAMENTO E POLIMENTO SUPRAGENGIVAIS (POR SEXTANTE)",
    # Task 15 (grupos das metas do CEO).
    "0307010015" => "CAPEAMENTO PULPAR",
    "0307010023" => "RESTAURAÇÃO DE DENTE DECÍDUO",
    "0307010040" => "RESTAURAÇÃO DE DENTE PERMANENTE POSTERIOR",
    "0307020070" => "PULPOTOMIA DENTÁRIA",
    "0307030016" => "RASPAGEM ALISAMENTO E POLIMENTO SUPRAGENGIVAIS",
    "0307030024" => "RASPAGEM ALISAMENTO SUBGENGIVAIS (POR SEXTANTE)",
    "0307030032" => "RASPAGEM CORONO-RADICULAR (POR SEXTANTE)",
    "0414020081" => "ENXERTO GENGIVAL",
    "0414020154" => "GENGIVECTOMIA (POR SEXTANTE)",
    "0414020162" => "GENGIVOPLASTIA (POR SEXTANTE)",
    "0414020375" => "TRATAMENTO CIRÚRGICO PERIODONTAL (POR SEXTANTE)",
    "0307020088" => "RETRATAMENTO ENDODÔNTICO EM DENTE PERMANENTE BI-RADICULAR",
    "0307020096" => "RETRATAMENTO ENDODÔNTICO EM DENTE PERMANENTE COM 3 OU MAIS RAÍZES",
    "0307020100" => "RETRATAMENTO ENDODÔNTICO EM DENTE PERMANENTE UNI-RADICULAR",
    "0307020118" => "SELAMENTO DE PERFURAÇÃO RADICULAR",
    "0201010232" => "BIÓPSIA DE GLÂNDULA SALIVAR",
    "0201010348" => "BIÓPSIA DE OSSO DO CRÂNIO E DA FACE",
    "0201010526" => "BIÓPSIA DOS TECIDOS MOLES DA BOCA",
    "0307010058" => "TRATAMENTO DE NEVRALGIAS FACIAIS",
    "0401010082" => "FRENÉCTOMIA/FRENOTOMIA.",
    "0404010512" => "SINUSOTOMIA TRANSMAXILAR",
    "0404020038" => "CORREÇÃO CIRÚRGICA DE FÍSTULA ORO-NASAL / ORO-SINUSAL",
    "0404020054" => "DRENAGEM DE ABSCESSO DA BOCA E ANEXOS",
    "0404020089" => "EXCISÃO DE RÂNULA OU FENÔMENO DE RETENÇÃO SALIVAR",
    "0404020097" => "EXCISÃO E SUTURA DE LESÃO NA BOCA",
    "0404020100" => "EXCISÃO EM CUNHA DE LÁBIO",
    "0404020313" => "RETIRADA DE CORPO ESTRANHO DOS OSSOS DA FACE",
    "0404020445" => "CONTENÇÃO DE DENTES POR SPLINTAGEM",
    "0404020488" => "OSTEOTOMIA DAS FRATURAS ALVEOLO-DENTÁRIAS",
    "0404020577" => "REDUÇÃO DE FRATURA ALVEOLO-DENTÁRIA SEM OSTEOSSÍNTESE",
    "0404020615" => "REDUÇÃO DE LUXAÇÃO TÊMPORO-MANDIBULAR",
    "0404020623" => "RETIRADA DE MATERIAL DE SÍNTESE ÓSSEA / DENTÁRIA",
    "0404020631" => "RETIRADA DE MEIOS DE FIXAÇÃO MAXILO-MANDIBULAR",
    "0404020674" => "RECONSTRUÇÃO PARCIAL DO LÁBIO TRAUMATIZADO",
    "0414010256" => "TRATAMENTO CIRÚRGICO DE FÍSTULA ORO-SINUSAL / ORO-NASAL",
    "0414010345" => "EXCISÃO DE CÁLCULO DE GLÂNDULA SALIVAR",
    "0414010361" => "EXERESE DE CISTO ODONTOGÊNICO E NÃO-ODONTOGÊNICO",
    "0414010388" => "TRATAMENTO CIRÚRGICO DE FÍSTULA INTRA / EXTRAORAL",
    "0414020022" => "APICECTOMIA COM OU SEM OBTURAÇÃO RETRÓGRADA",
    "0414020030" => "APROFUNDAMENTO DE VESTÍBULO ORAL (POR SEXTANTE)",
    "0414020049" => "CORREÇÃO DE BRIDAS MUSCULARES",
    "0414020057" => "CORREÇÃO DE IRREGULARIDADES DE REBORDO ALVEOLAR",
    "0414020065" => "CORREÇÃO DE TUBEROSIDADE DO MAXILAR",
    "0414020073" => "CURETAGEM PERIAPICAL",
    "0414020090" => "ENXERTO ÓSSEO DE ÁREA DOADORA INTRABUCAL",
    "0414020146" => "EXODONTIA MÚLTIPLA COM ALVEOLOPLASTIA POR SEXTANTE",
    "0414020170" => "GLOSSORRAFIA",
    "0414020200" => "MARSUPIALIZAÇÃO DE CISTOS E PSEUDOCISTOS",
    "0414020219" => "ODONTOSECÇÃO / RADILECTOMIA / TUNELIZAÇÃO",
    "0414020243" => "REIMPLANTE E TRANSPLANTE DENTAL (POR ELEMENTO)",
    "0414020278" => "REMOÇÃO DE DENTE RETIDO (INCLUSO / IMPACTADO)",
    "0414020294" => "REMOÇÃO DE TORUS E EXOSTOSES",
    "0414020359" => "TRATAMENTO CIRÚRGICO DE HEMORRAGIA BUCO-DENTAL",
    "0414020367" => "TRATAMENTO CIRÚRGICO PARA TRACIONAMENTO DENTAL",
    "0414020383" => "TRATAMENTO DE ALVEOLITE",
    "0414020405" => "ULOTOMIA/ULECTOMIA"
  }.freeze
  CIAP2 = { "D82" => "Doença dos dentes/gengivas" }.freeze

  def dental_city!(enabled: true)
    dental_sigtap!
    dental_ciap2!
    city = clinical_city!
    Platform::Features.set!(city: city, key: "dental_care", enabled: enabled, maintainer: ledi_maintainer!)
    # O dump (db/city_schema.rb) não leva linha: a lista que a migração insere
    # entra aqui, como os parâmetros da farmácia.
    DentalAuxiliaryProcedure.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  # A SIGTAP é imutável depois de ativa (como billing_sigtap!): a release da
  # competência do dia (a de sigtap_release!) nasce aqui com os códigos de
  # ClinicalRecordHelpers::SIGTAP e os odontológicos. Sem linha de CBO (sem
  # restrição), salvo `cbos` ({ código => [CBOs] }, ex.: 2232* e 3224*).
  # Chame antes de quem chama sigtap_release!.
  def dental_sigtap!(competence = Time.zone.today.strftime("%Y%m"), cbos: {})
    existing = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
    if existing
      raise "dental_sigtap! depois de sigtap_release!: a SIGTAP ativa é imutável; chame antes" unless
        SigtapProcedure.exists?(release_id: existing.id, code: SIGTAP.keys.first)

      return existing
    end
    release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "e" * 64, imported_by: "rspec",
                                         imported_at: Time.current, status: "importing")
    ClinicalRecordHelpers::SIGTAP.merge(SIGTAP).each { |code, name| SigtapProcedure.create!(release: release, code: code, name: name) }
    cbos.each { |code, list| list.each { |cbo| SigtapProcedureCbo.create!(release: release, procedure_code: code, cbo_code: cbo) } }
    release.update!(status: "active", activated_at: Time.current)
    release
  end

  # CIAP-2 da plataforma com o D82 (o problema do dental_body); imutável depois
  # de ativa, como a SIGTAP.
  def dental_ciap2!
    existing = TerminologyRelease.active.find_by(kind: "ciap2")
    if existing
      raise "dental_ciap2! depois de ciap2_release!: chame antes" unless Ciap2Code.exists?(release_id: existing.id, code: CIAP2.keys)

      return existing
    end
    ciap2_release!(ScreeningHelpers::CIAP2.merge(CIAP2))
  end

  def dentist!(unit, cbo: "223208") = screener!(unit, cbo: cbo, email: "dentista-#{SecureRandom.hex(3)}@cidade.gov.br")
  def auxiliary!(unit, cbo: "322430") = screener!(unit, cbo: cbo, email: "asb-#{SecureRandom.hex(3)}@cidade.gov.br")

  def dental_admin!
    User.joins(:memberships).merge(Membership.active.where(role: "municipal_admin")).first ||
      staff_with("admin-bucal-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
  end

  def ceo_unit!(type: "II", specialties: DentalCare::Catalog::CEO_SPECIALTIES)
    unit = create_unit("CEO #{SecureRandom.hex(2)}", kind: "ceo")
    CeoProfile.create!(health_unit: unit, ceo_type: type, specialties: specialties, updated_by_user: dental_admin!)
    unit
  end

  # Consulta odontológica iniciada pelo caminho real (Start com `kind`, Task 4).
  def dental_consultation!(unit:, by:, citizen:, baseline: false)
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: by)
    result = Consultations::Start.call(attendance: attendance, by: by, kind: "dental", baseline: baseline)
    raise "consulta odontológica não iniciou: #{result.reason}" if result.failure?

    result.payload.fetch(:consultation)
  end

  # Consulta odontológica em rascunho gravada direto, para specs de esquema e de
  # re-cifra (sem o caminho do Start): atendimento in_care chamado por `by`,
  # paciente resolvido.
  def dental_draft_row!(unit:, by:, citizen:, baseline: false, kind: "dental")
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: by)
    patient = Patients::Resolve.call(citizen).payload.fetch(:patient)
    Consultation.create!(attendance: attendance, patient: patient, author_user: by, professional_link: by.professional.links.active.first,
                         cbo_code: by.professional.links.active.first.cbo_code, status: "draft", kind: kind, baseline: baseline,
                         started_at: Time.current)
  end

  # Corpo de rascunho com um <dental_fields> válido. "A ou P" continua exigido
  # na consulta odontológica (Ruling 8): vai a avaliação.
  def dental_body(**over)
    dental = { "care_type" => 2, "dental_consultation_type" => 1, "oral_health_surveillance" => [ 99 ], "supplies" => [],
               "dental_outcomes" => [ 16 ], "pregnant" => false, "special_needs" => false,
               "procedures" => [ { "sigtap" => "0307010031", "location" => { "kind" => "face", "tooth" => 11, "face" => "M" } } ] }
    { "assessment" => "Cárie em esmalte, restauração indicada",
      "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "D82", "action" => "add",
                                  "onset_on" => "2026-09-01", "onset_precision" => "month" } ],
      "dental" => dental.merge((over.delete(:dental) || {}).transform_keys(&:to_s)) }.merge(over.transform_keys(&:to_s))
  end

  def finalized_dental!(unit:, by:, citizen:, outcome: { "outcome" => "discharged" }, baseline: false, **over)
    consultation = dental_consultation!(unit: unit, by: by, citizen: citizen, baseline: baseline)
    saved = Consultations::SaveDraft.call(consultation: consultation, params: dental_body(**over), by: by)
    raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

    result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: outcome, by: by)
    raise "finalização recusada: #{result.reason} #{result.details}" if result.failure?

    consultation.reload
  end
end

RSpec.configure { |c| c.include DentalHelpers }
