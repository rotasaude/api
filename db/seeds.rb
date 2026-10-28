# Seeds de desenvolvimento. Idempotente: `bin/rails db:seed` pode rodar N vezes.
#
#   - PLATAFORMA: operador dev@local / dev-password (Operator + MFA, otp_secret
#     fixo) — loga no console, host admin.* (Operators::SessionsController); e um
#     canal WhatsApp por cidade (CityChannel); e o mantenedor dev@local /
#     dev-password (Maintainer + TOTP fixo), que é OUTRA tabela e é a única
#     conta que o console de manutenção aceita — ver `lib/dev_maintainer.rb`.
#   - CADA CIDADE (curitiba, maringa), dentro da conexão dela: admin@<slug>.demo /
#     dev-password como municipal_admin (também com TOTP, para a tela Equipe), o
#     city_profile, um AlertRecipient de e-mail ativo, protocolo ATIVO
#     (triage-respiratoria), uma triagem completa e o relatório; e o elenco do
#     ciclo assinado (autor, duas revisoras e publisher, todos com TOTP) mais um
#     rascunho de verdade do protocolo (achado ou criado na próxima versão
#     livre), criados por `SignatureCrew` (plano 2026-09-23) — ver
#     `lib/signature_crew.rb`.
#     O analyst (analise@<slug>.demo) e ~6 meses de histórico consolidado para o Analytics vêm de `lib/analytics_crew.rb` (módulo 14).
#     Modo de prontuário (módulo 16): SIGTAP reduzida, CPF dos profissionais, credencial cadsus simulada e um retrato do CNES — ver lib/record_mode_crew.rb. A semente não altera record_mode nem liga interruptor (cidade nova nasce com record_mode off, o padrão da tabela cities).
#     Linha do tempo (módulo 20): patient_timeline ligado; Maringá em modo integrado com o PEC simulado — ver lib/timeline_crew.rb.
#     Os protocolos do catálogo (saúde do idoso, saúde mental e aprofundamento), a família avó+neto no mesmo celular e o idoso restrito a dois bairros em Curitiba vêm de `lib/triage_catalog_crew.rb` (módulo 15).
#     A base de tipos de atendimento, o modelo "Manhã" nos turnos da médica (Curitiba), os turnos da semana da médica e da enfermeira e o idoso com regra de agendamento vêm de `lib/scheduling_crew.rb` (módulo 17).
#     Linhas de cuidado (módulo 23): care_lines ligado em Curitiba, linhas adotadas e a própria de saúde mental, a técnica de enfermagem (tecnica@<slug>.demo, também na recepção) e as pessoas das provas na UBS Jardim das Flores — ver lib/care_lines_crew.rb.
#     Cadastro territorial (módulo 24a): territory_registry ligado em Curitiba, a ACS (acs@<slug>.demo), as microáreas 01 e 02 da equipe da UBS Jardim das Flores, quatro domicílios e os cadastros da prova (válido, a vencer, vencido, sem identificador, recusa, óbito, mudança) — ver lib/territory_registry_crew.rb.
#     DDD, telefones, e-mails e canal diferem por cidade, para o isolamento ficar
#     visível fora da suíte.
#
# Pré-requisito: as cidades ativas no catálogo, com banco e schema —
# `bin/rails city:dev_baseline` (o start.sh já roda). Cidade ausente ou inativa é
# pulada com aviso.
#
# Operador exige MFA/TOTP a cada login (ADR-0011). Em dev usamos um `otp_secret`
# FIXO (override por env) para que a entrada no seu autenticador continue válida
# após cada reset — caso contrário você teria que re-enrolar toda vez.
#
# NUNCA roda em produção — senhas e segredo fixos são só para ambiente local.
if Rota.deployed?
  warn "[seeds] pulando: seeds de dev não rodam em ambiente publicado (#{Rails.env})"
else
  require Rails.root.join("lib/signature_crew").to_s
  require Rails.root.join("lib/dev_maintainer").to_s
  require Rails.root.join("lib/professional_crew").to_s
  require Rails.root.join("lib/territory_crew").to_s
  require Rails.root.join("lib/campaign_crew").to_s
  require Rails.root.join("lib/analytics_crew").to_s
  require Rails.root.join("lib/triage_catalog_crew").to_s
  require Rails.root.join("lib/scheduling_crew").to_s
  require Rails.root.join("lib/screening_crew").to_s
  require Rails.root.join("lib/clinical_record_crew").to_s
  require Rails.root.join("lib/digital_signature_crew").to_s
  require Rails.root.join("lib/clinical_documents_crew").to_s
  require Rails.root.join("lib/controlled_prescriptions_crew").to_s
  require Rails.root.join("lib/timeline_crew").to_s
  require Rails.root.join("lib/exam_crew").to_s
  require Rails.root.join("lib/lab_crew").to_s
  require Rails.root.join("lib/lab_qc_crew").to_s
  require Rails.root.join("lib/billing_crew").to_s
  require Rails.root.join("lib/care_lines_crew").to_s
  require Rails.root.join("lib/territory_registry_crew").to_s
  require Rails.root.join("lib/surveillance_crew").to_s
  require Rails.root.join("lib/record_mode_crew").to_s
  require Rails.root.join("lib/ledi_crew").to_s

  password = ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password")

  # ── Operador de plataforma + MFA ──────────────────────────────────────────────
  # otp_secret fixo (dev) para o autenticador sobreviver a resets. Só é setado
  # quando o operador ainda não tem MFA (não clobbera um segredo já existente).
  operator = Operator.find_or_initialize_by(email_address: "dev@local")
  operator.password = password
  unless operator.otp_enabled? && operator.otp_secret.present?
    operator.otp_secret  = ENV.fetch("DEV_OPERATOR_OTP_SECRET", "TQLRHWIAKEISPIW6YY3IAKGCLVNPF4EV")
    operator.otp_enabled = true
  end
  operator.save!
  puts "[seeds] operador .... #{operator.email_address} / #{password} + MFA (otp_secret fixo) → console admin.*"

  # ── Mantenedor da API de manutenção ───────────────────────────────────────────
  # Conta de OUTRA tabela, não o operador acima: o console de manutenção
  # (apps/maintenance) só aceita Maintainer. Mesmo e-mail e mesma senha de dev
  # para não haver duas coisas para lembrar; segredo de TOTP próprio, fixo.
  if MaintenanceApi.enabled?
    maintainer = DevMaintainer.ensure!(email_address: "dev@local", password: password)
    puts "[seeds] mantenedor .. #{maintainer.email_address} / #{password} + MFA → http://maintenance.localhost:5177"
    puts "[seeds]               #{DevMaintainer.otpauth_uri(maintainer)}"
  else
    warn "[seeds] API de manutenção desligada neste ambiente — mantenedor de dev não semeado"
  end

  # ── Terminologias (módulo 16, spec 2026-10-05 §10) ──────────────────────────
  sigtap = RecordModeCrew.seed_platform!
  puts "[seeds] SIGTAP ....... #{sigtap[:sigtap]} #{sigtap[:imported] ? 'importada (recorte de dev)' : 'já ativa'}"

  # Exames do módulo 21a (ADR 0036): garante os quatro procedimentos do grupo 02
  # na competência corrente. Republica o recorte de dev se a release ativa é o
  # recorte e não os tem; uma SIGTAP real ativa nunca é tocada (só avisa no log).
  exams_sigtap = ExamCrew.seed_platform!
  puts "[seeds] SIGTAP exames . #{exams_sigtap[:sigtap]} #{{ republished: 'republicada (recorte de dev)', real_sigtap: 'SIGTAP real ativa; exames do 21a não verificados', complete: 'já completa' }.fetch(exams_sigtap[:status])}"

  # Catálogo-base do laboratório (módulo 21b, ADR 0037).
  lab_templates = LabCrew.seed_platform!
  puts "[seeds] catálogo-base laboratório . #{lab_templates[:created]} exames novos; fora da SIGTAP: #{lab_templates[:skipped].join(', ').presence || 'nenhum'}"

  # Faturamento (módulo 22, ADR 0039): recorte SIGTAP de dev com instrumento,
  # CBO e CID no mês e no anterior; SIGTAP real ativa nunca é tocada.
  billing_sigtap = BillingCrew.seed_platform!
  puts "[seeds] SIGTAP faturamento . #{billing_sigtap[:competences].join(', ')} #{{ republished: 'republicada (recorte de dev)', real_sigtap: 'SIGTAP real ativa; não verificada', complete: 'já completa' }.fetch(billing_sigtap[:status])}"

  ciap2 = ScreeningCrew.seed_platform!
  puts "[seeds] CIAP-2 ....... #{ciap2[:ciap2]} #{ciap2[:imported] ? 'importada (recorte de dev)' : 'já ativa'}"

  # ── Terminologias da consulta (módulo 19, spec 2026-10-07 §9) ─────────────────
  # Depois do ScreeningCrew: o recorte de CIAP-2 do acolhimento (32 códigos) já
  # fica ativo; aqui só entra a CID-10 (e a CIAP-2 só se ainda faltar).
  terms = ClinicalRecordCrew.seed_platform!
  puts "[seeds] CIAP-2/CID-10 #{terms.map { |kind, imported| "#{kind} #{imported ? 'importada (recorte de dev)' : 'já ativa'}" }.join('; ')}"

  # Linhas de cuidado (módulo 23, ADR 0040): catálogo-base C2–C7, só a v1
  # (carga idempotente; a v2 é publicada na prova do maintenance).
  puts "[seeds] linhas de cuidado (catálogo-base) . #{CareLinesCrew.seed_platform![:created]} versões novas"

  # Lista nacional de notificação compulsória (módulo 25, ADR 0043): a versão 1
  # do YAML versionado (idempotente; nunca sobrescreve a curadoria do maintenance).
  puts "[seeds] lista de notificação compulsória . #{Surveillance::DiseaseList::Load.call[:created]} versões novas"

  # ── Medicamentos (módulo 19c, ADR 0033) ───────────────────────────────────────
  # Recorte real do CATMAT (sem rede) e listas Anvisa do repositório.
  puts "[seeds] medicamentos . #{ClinicalDocumentsCrew.seed_platform!.inspect}"

  # Mesmo protocolo que o provisionamento semeia em rascunho (Plano 4); aqui ativo.
  protocol_defn = CityTemplates.protocol.fetch(:definition)

  { "curitiba" => %w[41 4106902], "maringa" => %w[44 4115200] }.each do |slug, (ddd, ibge_code)|
    city = City.find_by(slug: slug)
    if city.nil? || !city.servable?
      warn "[seeds] cidade '#{slug}' ausente ou não ativa no catálogo — pulada (rode bin/rails city:dev_baseline)"
      next
    end

    # ── Canal WhatsApp (plataforma) ─────────────────────────────────────────────
    tag = slug.upcase
    channel = CityChannel.find_or_create_by!(phone_number_id: "PNID-#{tag}-DEV") do |c|
      c.city                 = city
      c.waba_id              = "WABA-#{tag}-DEV"
      c.display_phone_number = "+55#{ddd}999990000"
      c.access_token         = "DEV-WHATSAPP-TOKEN-#{tag}"
      c.active               = true
    end

    Current.set(city: city) do
      CityConnection.with(city) do
        # ── Usuário municipal (Dashboard) ─────────────────────────────────────
        muni_admin = User.find_or_initialize_by(email_address: "admin@#{slug}.demo")
        muni_admin.password = password
        muni_admin.save!
        Membership.find_or_create_by!(user: muni_admin, role: "municipal_admin") do |m|
          m.granted_at = Time.current
        end

        # ── Identidade da cidade no banco dela (city_profile, Plano 4) ────────
        profile = CityProfile.current || CityProfile.new
        profile.update!(name: city.name, uf: city.uf, ibge_code: ibge_code)

        # ── Destinatário de alerta urgente (R37) ──────────────────────────────
        # DispatchMunicipalityAlertJob entrega ao primeiro AlertRecipient de email
        # ativo da cidade e levanta NoAlertRecipient sem nenhum. Um por cidade, no
        # banco dela. city_profile não carrega destino de alerta (Plano 4).
        alert_recipient = AlertRecipient.find_or_initialize_by(
          channel: "email", destination: ENV.fetch("DEV_ALERT_EMAIL", "alertas@#{slug}.demo")
        )
        alert_recipient.active = true
        alert_recipient.save!

        # ── Demo ponta-a-ponta ────────────────────────────────────────────────
        protocol = ProtocolDefinition.find_or_create_by!(name: "triage-respiratoria", version: 1) do |p|
          p.status     = "active"
          p.definition = protocol_defn
        end

        # Linha-base (fatia 2 das assinaturas): o protocolo nasce ativo no seed,
        # como uma versão que já estava em uso antes das assinaturas.
        unless protocol.activations.exists?
          protocol.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil,
                                       created_at: protocol.activated_at || protocol.created_at)
        end

        # state "consented": a pessoa consentiu e concluiu a triagem — é o estado
        # que os painéis live/funil de Conversas contam. created_at ~5 min antes
        # de completed_at para o KPI avgToCompleteMin exibir uma duração realista.
        convo  = Conversation.find_or_create_by!(phone: "+55#{ddd}999990001") { |c| c.state = "consented" }
        triage = Triage.where(conversation_id: convo.id, protocol_definition_id: protocol.id).first
        triage ||= Triage.create!(
          conversation: convo, protocol_definition: protocol, protocol_name: "triage-respiratoria",
          status: "completed", tier: "alta", priority: 1,
          created_at: 5.minutes.ago, completed_at: Time.current,
          answers: { "tosse" => "true", "febre" => "true" },
          outcome: { "status" => "terminal", "tier" => "alta", "priority" => 1,
                     "trail" => [ { "step" => "tosse", "answer" => "true" }, { "step" => "febre", "answer" => "true" } ] }
        )
        GenerateReportJob.new.handle(triage_id: triage.id, status: "terminal", tier: "alta", priority: 1)
        report = ReportSnapshot.find_by(triage_id: triage.id)

        # ── Elenco do ciclo assinado (plano 2026-09-23) ───────────────────────
        # Autor, duas revisoras e publisher com TOTP fixo, mais um rascunho de
        # verdade (achado em `draft`, ou criado na próxima versão livre) pelo
        # command de autoria — sem isso, exercitar assinatura no navegador
        # exige cadastrar quatro autenticadores à mão a cada reset. O admin
        # municipal também ganha TOTP: a tela Equipe pede step-up para
        # conceder papel.
        SignatureCrew.ensure_totp(muni_admin, secret_env: "DEV_MUNI_ADMIN_OTP_SECRET",
                                              default_secret: "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
        crew = SignatureCrew.seed_current_city(slug: slug, password: password)
        puts "[seeds] admin ...... #{muni_admin.email_address} / #{password} + MFA → #{SignatureCrew.otpauth_uri(muni_admin)}"
        crew[:accounts].each do |account|
          puts "[seeds] #{account[:role].ljust(18)} #{account[:email]} / #{password} + MFA → #{account[:otpauth_uri]}"
        end
        puts crew[:draft] ? "[seeds] rascunho ... #{crew[:draft][:name]} v#{crew[:draft][:version]} (#{crew[:draft][:status]})" \
                          : "[seeds] rascunho ... NÃO criado (veja o retorno do command)"

        # ── Profissionais (módulo 10, spec 2026-09-27 §6) ─────────────────────
        pros = ProfessionalCrew.seed_current_city(slug: slug, password: password, admin: muni_admin)
        pros[:accounts].each do |account|
          puts "[seeds] #{account[:role].ljust(18)} #{account[:email]} / #{password} + MFA → #{account[:otpauth_uri]}"
        end
        pros[:professionals].each do |p|
          puts "[seeds] profissional . #{p[:email]} — #{p[:name]} (#{p[:links]} vínculos, #{p[:shifts]} turnos)"
        end

        # ── Território (módulo 11, spec 2026-09-28 §8) ────────────────────────
        # Depois do ProfessionalCrew: a cobertura da semente liga as unidades dele.
        territory = Territory::Seed.call(path: Territory::Seed.path_for(slug))
        puts "[seeds] território .. #{territory.created} bairros criados, #{territory.existing} já existentes"
        territory.warnings.each { |warning| puts "[seeds] território .. aviso: #{warning}" }
        demo = TerritoryCrew.seed_current_city(slug: slug, ddd: ddd)
        puts "[seeds] território .. #{demo[:units_with_address]} unidades com endereço, " \
             "#{demo[:citizens]} cidadãos de demonstração (#{demo[:new_triages]} triagens novas)"

        # ── Campanhas (módulo 12, spec 2026-09-29 §10) ────────────────────────
        # Depois do território e dos profissionais: usa os bairros e as unidades.
        campaigns = CampaignCrew.seed_current_city(slug: slug, ddd: ddd, password: password)
        puts "[seeds] campaign_manager   #{campaigns[:account][:email]} / #{password} + MFA → #{campaigns[:account][:otpauth_uri]}"
        puts "[seeds] campanhas .. #{campaigns[:citizens]} cidadãos (#{campaigns[:opted_in]} com opt-in de SMS, " \
             "#{campaigns[:new_histories]} históricos novos); chave de SMS da cidade desligada"

        # ── Analytics (módulo 14, spec 2026-09-30 §11) ────────────────────────
        # Depois do território, dos profissionais e do elenco do ciclo assinado:
        # usa bairros, unidades, recepção, autor, revisoras e publisher. A
        # primeira vez leva uns segundos por cidade (~6 meses de histórico).
        analytics = AnalyticsCrew.seed_current_city(slug: slug, ddd: ddd, password: password)
        puts "[seeds] analyst .......... #{analytics[:account][:email]} / #{password} + MFA → #{analytics[:account][:otpauth_uri]}"
        puts "[seeds] analytics .. #{analytics[:protocol][:name]} v#{analytics[:protocol][:version]} " \
             "(#{analytics[:protocol][:status]}), #{analytics[:new_triages]} triagens novas, " \
             "#{analytics[:runs]} blocos consolidados#{analytics[:failed] ? " — FALHOU: #{analytics[:failed]}" : ''}"

        # ── Modo de prontuário (módulo 16, spec 2026-10-05 §10) ───────────────
        # Depois do ProfessionalCrew: o retrato do CNES usa as unidades e os
        # profissionais dele. Não altera record_mode nem liga interruptor
        # (cidade nova nasce com record_mode off, o padrão da tabela cities).
        record = RecordModeCrew.seed_current_city(slug: slug, admin: muni_admin)
        puts "[seeds] CNES ......... #{record[:ibge_code]} #{record[:cnes_competence]}: #{record[:establishments]} " \
             "estabelecimentos, #{record[:teams]} equipes, #{record[:bonds]} vínculos; credencial cadsus simulada"

        # ── Produção e-SUS (módulo 16, spec §10) ──────────────────────────────
        # Fila LEDI com todos os estados na competência corrente; nada é
        # enviado enquanto o interruptor ledi_export estiver desligado ou
        # record_mode=off. Esta semente não altera record_mode nem liga interruptor.
        ledi = LediCrew.seed_current_city(slug: slug)
        puts "[seeds] produção e-SUS .. #{ledi[:created]} fichas sintéticas na fila (não enviadas)"

        # ── Catálogo de triagens (módulo 15, spec 2026-10-05 §10) ─────────────
        # Depois do elenco do ciclo assinado e do território: usa autor,
        # revisoras, publisher, admin e bairros.
        catalog = TriageCatalogCrew.seed_current_city(slug: slug, ddd: ddd)
        puts "[seeds] catálogo .... #{catalog[:protocols].join(', ')} ativos" \
             "#{catalog[:restricted_neighborhoods].any? ? "; idoso só em #{catalog[:restricted_neighborhoods].join(' e ')}" : ''}"
        puts "[seeds] títulos ..... #{catalog[:titled].join(', ')} (versão nova assinada)" if catalog[:titled].any?
        catalog[:family].each { |p| puts "[seeds] família ..... #{p[:cpf_masked]} (#{p[:age]} anos, #{p[:sex]})" }

        # ── Agenda (módulo 17, spec 2026-10-05 §10) ───────────────────────────
        # Depois do catálogo: usa o saude-do-idoso ativo, a médica e a enfermeira.
        agenda = SchedulingCrew.seed_current_city(slug: slug)
        puts "[seeds] agenda ...... #{agenda[:types]} tipos; modelo: #{agenda[:template] || 'nenhum'}; " \
             "#{agenda[:new_shifts]} turnos novos, #{agenda[:templated]} com modelo; #{agenda[:protocol]} com agendamento"

        # ── Acolhimento (módulo 18, spec 2026-10-07 §10) ──────────────────────
        # Depois da agenda: usa o elenco do ciclo assinado, a UBS, a técnica e a recepção.
        screening = ScreeningCrew.seed_current_city(slug: slug, ddd: ddd)
        puts "[seeds] acolhimento . #{screening[:protocol]}; técnica na UBS (#{screening[:technician_link]}); " \
             "#{screening[:walk_ins]} check-ins novos de demanda espontânea"

        # ── Prontuário (módulo 19, spec 2026-10-07 §9) ────────────────────────
        # Depois do acolhimento: usa a UBS, a médica, a enfermeira e a recepção.
        clinical = ClinicalRecordCrew.seed_current_city(slug: slug, ddd: ddd)
        puts "[seeds] prontuário ... interruptor #{clinical[:switch]}; #{clinical[:patient]}: #{clinical[:consultation]}"

        # ── Assinatura digital (módulo 19b, ADR 0032) ─────────────────────────
        # Depois do prontuário: só Curitiba liga digital_signature + PSC simulado.
        signature = DigitalSignatureCrew.seed_current_city(slug: slug)
        puts "[seeds] assinatura .. interruptores #{signature[:switch]}; #{signature[:professionals].size} profissionais com CPF novo"

        # ── Documentos clínicos (módulo 19c, ADR 0033) ────────────────────────
        documents = ClinicalDocumentsCrew.seed_current_city(slug: slug)
        puts "[seeds] documentos .. #{documents.inspect}"

        # ── Receita controlada (módulo 19d, ADR 0034) ────────────────────────
        # Depois do DigitalSignatureCrew e do ClinicalDocumentsCrew.
        controlled = ControlledPrescriptionsCrew.seed_current_city(slug: slug, password: password, admin: muni_admin)
        puts "[seeds] receita controlada .. #{controlled[:switch]}#{controlled[:dentist] ? " — #{controlled[:dentist]} — estoque: #{controlled[:block]}" : ''}"

        # ── Linha do tempo (módulo 20, ADR 0035) ─────────────────────────────
        # Por último: Maringá vira a cidade integrada com o PEC simulado.
        timeline = TimelineCrew.seed_current_city(slug: slug, ddd: ddd)
        puts "[seeds] linha do tempo .. #{timeline[:switch]}#{timeline[:simulator] ? " — simulador: #{timeline[:simulator]} (CNES #{timeline[:cnes]})" : ''}"

        # ── Rastreamento de exames (módulo 21a, ADR 0036) ─────────────────────
        # Depois da linha do tempo: Maringá já é integrada (exam_pec_bridge).
        exams = ExamCrew.seed_current_city(slug: slug, ddd: ddd, password: password)
        puts "[seeds] exames ...... #{exams[:switch]}; #{exams[:orders]} guias novas#{"; equipe #{exams[:team]}" if exams[:team]}"
        Array(exams[:users]).each { |u| puts "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }

        # ── Laboratório municipal (módulo 21b, ADR 0037) ──────────────────────
        # Depois do ExamCrew (o prestador) e do ProfessionalCrew (as UBS).
        lab = LabCrew.seed_current_city(slug: slug, password: password, admin: muni_admin)
        puts "[seeds] laboratório .. #{lab[:switch]}; #{lab[:exams]} exames novos adotados"
        Array(lab[:users]).each { |u| puts "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }

        # ── Qualidade e insumos do laboratório (módulo 21c, ADR 0038) ─────────
        # Depois do LabCrew (laboratório, exames e as contas que operam o 21c).
        qc = LabQcCrew.seed_current_city(slug: slug, admin: muni_admin)
        puts "[seeds] qualidade ... #{qc[:switch]}#{"; #{qc[:created].join(', ')}" if qc[:created].any?}"

        # ── Procedimentos e faturamento BPA (módulo 22, ADR 0039) ─────────────
        # Depois do LabCrew (laboratório e liberadores) e do ProfessionalCrew (UPA e vínculos).
        billing = BillingCrew.seed_current_city(slug: slug, password: password, admin: muni_admin)
        puts "[seeds] faturamento . #{billing[:switch]}#{"; #{billing[:created].join(', ')}" if billing[:created].any?}"
        Array(billing[:users]).each { |u| puts "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }

        # ── Linhas de cuidado (módulo 23, ADR 0040) ───────────────────────────
        # Depois do ClinicalRecordCrew (UBS, médica, enfermeira, recepção, CIAP/CID),
        # do TriageCatalogCrew (saude-mental) e do ExamCrew (equipe da UBS, reaproveitada).
        care = CareLinesCrew.seed_current_city(slug: slug, ddd: ddd, password: password)
        puts "[seeds] linhas de cuidado . #{care[:switch]}" \
             "#{"; equipe #{care[:team]}; #{care[:people].size} pessoas, #{care[:pending]} sugestões pendentes" if care[:people].any?}"
        Array(care[:users]).each { |u| puts "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }

        # ── Cadastro territorial (módulo 24a, ADR 0042) ───────────────────────
        # Depois do CareLinesCrew: usa a UBS, a equipe, a enfermeira e as pessoas dele.
        registry = TerritoryRegistryCrew.seed_current_city(slug: slug, ddd: ddd, password: password)
        puts "[seeds] cadastro territorial . #{registry[:switch]}" \
             "#{"; equipe #{registry[:team]}; #{registry[:households]} domicílios, #{registry[:registrations]} cadastros" if registry[:team]}"
        Array(registry[:micro_areas]).each { |area| puts "[seeds]               microárea #{area}" }
        puts "[seeds]               validade #{registry[:status].map { |k, v| "#{k} #{v}" }.join(', ')}; fichas #{registry[:fichas]}" if registry[:status]
        Array(registry[:users]).each { |u| puts "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }

        # ── Vigilância epidemiológica (módulo 25, ADR 0043) ───────────────────
        # Depois do TerritoryRegistryCrew: usa a UBS, a médica, a recepção e as pessoas
        # do 23 e do 24a. Só e-mail, papel e otpauth: nunca dado de paciente.
        surveillance = SurveillanceCrew.seed_current_city(slug: slug, ddd: ddd, password: password)
        puts "[seeds] vigilância .. #{surveillance[:switch]}" \
             "#{"; semana #{surveillance[:week]}; #{surveillance[:notifications]} notificações, #{surveillance[:negatives]} negativa(s); #{surveillance[:safety_net]}" if surveillance[:week]}"
        puts "[seeds]               fila #{surveillance[:queue].map { |k, v| "#{k} #{v}" }.join(', ')}" if surveillance[:queue]
        Array(surveillance[:users]).each { |u| puts "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }

        puts "[seeds] cidade ...... #{city.name} (#{city.slug}/#{city.uf}, #{city.status})"
        puts "  perfil ...... #{profile.name}/#{profile.uf} IBGE #{profile.ibge_code}"
        puts "  municipal ... #{muni_admin.email_address} / #{password}  → dashboard"
        puts "  alerta ...... #{alert_recipient.destination} (email, active)"
        puts "  canal ....... #{channel.phone_number_id} (active)"
        puts "  protocolo ... #{protocol.name} v#{protocol.version} (#{protocol.status})"
        puts "  relatório ... #{report&.url}"
      end
    end
  end
end

# Dataset opcional e pesado dos painéis (todas as cidades de dev). Fora por
# padrão; o seed base fica enxuto. Ligue com SEED_DASHBOARD_DEMO=1 bin/rails db:seed
# (ou bin/rails db:seed:demo). Ver lib/dashboard_demo.rb.
if ENV["SEED_DASHBOARD_DEMO"] == "1" && !Rota.deployed?
  load Rails.root.join("db/seeds/dashboard_demo.rb")
end
