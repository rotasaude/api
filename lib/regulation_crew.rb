require "active_support/testing/time_helpers"
require "tmpdir"
require "zlib"
require Rails.root.join("lib/sigtap_sample").to_s
require_relative "signature_crew"
require_relative "screening_crew"
require_relative "clinical_record_crew"
require_relative "care_lines_crew"

# Semente de dev do módulo 26a (ADR 0044), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, care_regulation LIGADO pelo
# mantenedor de dev; a reguladora Rosângela Maria Kowalski
# (regulacao.municipal@, papel care_regulator, OTP fixo; o regulacao@ é a
# reguladora de exames do 21a e fica como está; o usuário não tem campo de
# nome, o nome é o da persona); a unidade própria "Centro Municipal de
# Especialidades Vila Hauer" e três prestadores fictícios; as ofertas do mês
# corrente; a lista do enfermeiro; e os pedidos abaixo, todos pelos comandos
# do app (Consultations::Start/SaveDraft/Finalize, CareRegulation::SaveDraft,
# Authorize, Decide, MarkExternal, ScheduleExternal, RecordOutcome), com a
# médica da UBS Jardim das Flores. As datas passadas vêm de travel_to em volta
# do comando, sempre até um segundo antes de agora.
#
#   pedido  alvo          cor       pedido há  situação                         quem
#   1       cardiologia   vermelho  10 dias    pending (vencido no topo)         pessoa nova
#   2       cardiologia   amarelo   40 dias    pending (vencido)                 pessoa nova
#   3       oftalmologia  verde      5 dias    pending                           pessoa nova
#   4       cardiologia   amarelo    3 dias    pending (pular 1 e 2 exige motivo) pessoa nova
#   5       ortopedia     amarelo   20 dias    authorized no consórcio (cota 1/1) pessoa nova
#   6       cardiologia   verde     50 dias    authorized na própria (17 aberto)  José (23)
#   7       oftalmologia  amarelo   25 dias    scheduled na contratada (+12 dias) pessoa nova
#   8       endoscopia    verde     15 dias    returned (complemento)            pessoa nova
#   9       ortopedia     azul      30 dias    external (SISREG 202610280001)    pessoa nova
#   10      oftalmologia  verde     45 dias    completed                         Sebastião (23)
#
# Pessoas: o José e o Sebastião do CareLinesCrew (par validado, paciente e
# consulta; o pedido 6 da rede própria exige o par validado). As outras
# pessoas do 23 e as do 24a não servem: ganhar consulta quebraria as provas do
# 23 (Maria, Juliana, Rafael, Miguel, Osvaldo da P18) ou elas não têm par para
# o check-in (as digitadas no 24a). As oito restantes são pessoas novas, com
# par validado (RegisterPerson, Verify) e celular +55 <ddd> 91111-NNNN.
#
# A CID-10 de dev é um recorte: a semente republica o recorte "dev-*" com os
# diagnósticos dos pedidos (como a vigilância faz com o A90); uma release
# real ativa nunca é tocada. A SIGTAP de dev (SigtapSample) leva a EGD
# (0209010037) e os outros reguláveis desde o 26a; seed_platform! republica o
# recorte da competência corrente e da anterior quando faltam (molde do
# BillingCrew). Idempotente: o pedido existente da pessoa × alvo é retomado
# do estado em que está, nunca duplicado. Só e-mail, papel e otpauth na saída.
class RegulationCrew
  UNIT = CareLinesCrew::UNIT
  DEV_MAINTAINER = "dev@local".freeze
  PHONE_PREFIX = "91111".freeze
  REGULATOR = { email_prefix: "regulacao.municipal", name: "Rosângela Maria Kowalski", role: "care_regulator",
                secret_env: "DEV_CARE_REGULATOR_OTP_SECRET", default_secret: "REGULACAOMUNICIPALSEMENTEDEVCWBA" }.freeze
  OWN_UNIT = "Centro Municipal de Especialidades Vila Hauer".freeze
  PROVIDERS = {
    own: { name: OWN_UNIT, kind: "own" },
    contracted: { name: "Clínica de Olhos Araucária", kind: "contracted" },
    consortium: { name: "Consórcio Intermunicipal de Saúde Vale do Iguaçu", kind: "consortium" },
    ppi: { name: "Hospital Regional Campos do Tenente", kind: "ppi" }
  }.freeze
  CARDIOLOGY = "225120".freeze
  OPHTHALMOLOGY = "225265".freeze
  ORTHOPEDICS = "225270".freeze
  ENDOSCOPY = "0209010037".freeze
  OFFERS = [
    { provider: :own, type: "specialty", code: CARDIOLOGY, quantity: 10 },
    { provider: :contracted, type: "specialty", code: OPHTHALMOLOGY, quantity: 8 },
    { provider: :consortium, type: "specialty", code: ORTHOPEDICS, quantity: 1 },
    { provider: :ppi, type: "procedure", code: ENDOSCOPY, quantity: 5 }
  ].freeze
  # Lista do enfermeiro: ginecologia e obstetrícia, pediatria.
  NURSE_ITEMS = %w[225250 225124].freeze

  # Diagnósticos dos pedidos (CID-10 real, DATASUS), para o recorte de dev.
  CID10 = { "I20" => "Angina pectoris", "I49" => "Outras arritmias cardíacas", "H25" => "Catarata senil", "H40" => "Glaucoma",
            "M17" => "Gonartrose [artrose do joelho]", "M54" => "Dorsalgia", "K21" => "Doença de refluxo gastroesofágico",
            "I10" => "Hipertensão essencial (primária)" }.freeze
  CID10_VERSION = "dev-regulacao".freeze

  # Pessoas novas (par validado + paciente).
  PEOPLE = {
    roberto: { phone: 1, name: "Roberto Carlos Mendes", mother: "Ivete Mendes", birth: "1961-02-17", sex: "male" },
    marcia: { phone: 2, name: "Márcia Regina Kuster", mother: "Hilda Kuster", birth: "1966-09-04", sex: "female" },
    iolanda: { phone: 3, name: "Iolanda Pires Bittencourt", mother: "Dirce Pires", birth: "1949-05-23", sex: "female" },
    paulo: { phone: 4, name: "Paulo Sérgio Wosniak", mother: "Irene Wosniak", birth: "1972-11-30", sex: "male" },
    neusa: { phone: 5, name: "Neusa Aparecida Correia", mother: "Luzia Correia", birth: "1958-03-08", sex: "female" },
    valdir: { phone: 6, name: "Valdir Antônio Schmidt", mother: "Olga Schmidt", birth: "1955-07-14", sex: "male" },
    cristiane: { phone: 7, name: "Cristiane Lopes Farias", mother: "Marli Lopes", birth: "1984-01-26", sex: "female" },
    leonardo: { phone: 8, name: "Leonardo Henrique Prado", mother: "Sueli Prado", birth: "1990-10-02", sex: "male" }
  }.freeze

  # Os pedidos, na ordem de gravação. who: pessoa nova (PEOPLE) ou do
  # CareLinesCrew (care_lines: true). to: a situação final.
  REQUESTS = [
    { n: 1, who: :roberto, type: "specialty", code: CARDIOLOGY, cid10: "I20", color: "red", days_ago: 10, to: "pending",
      justification: "Dor torácica em aperto aos pequenos esforços há duas semanas, com piora progressiva; ECG com " \
                     "infradesnivelamento de ST em parede lateral. Solicito avaliação cardiológica com prioridade." },
    { n: 2, who: :marcia, type: "specialty", code: CARDIOLOGY, cid10: "I10", color: "yellow", days_ago: 40, to: "pending",
      justification: "Hipertensão resistente em uso de três anti-hipertensivos em dose plena (losartana, anlodipino e " \
                     "hidroclorotiazida), PA média de 168/102 mmHg nas últimas três consultas." },
    { n: 3, who: :iolanda, type: "specialty", code: OPHTHALMOLOGY, cid10: "H25", color: "green", days_ago: 5, to: "pending",
      justification: "Baixa acuidade visual progressiva bilateral há um ano, pior à direita; opacidade de cristalino à " \
                     "oftalmoscopia direta. Avaliação para cirurgia de catarata." },
    { n: 4, who: :paulo, type: "specialty", code: CARDIOLOGY, cid10: "I49", color: "yellow", days_ago: 3, to: "pending",
      justification: "Palpitações recorrentes há três meses, ECG com extrassístoles ventriculares frequentes; sem síncope. " \
                     "Solicito avaliação cardiológica e Holter de 24 horas." },
    { n: 5, who: :neusa, type: "specialty", code: ORTHOPEDICS, cid10: "M17", color: "yellow", days_ago: 20, to: "authorized",
      offer: :consortium,
      justification: "Gonalgia bilateral mecânica há dois anos, pior à esquerda, com limitação para marcha acima de 200 metros; " \
                     "radiografia com redução do espaço articular medial. Sem melhora com fisioterapia e analgesia." },
    { n: 6, who: :jose, care_lines: true, type: "specialty", code: CARDIOLOGY, cid10: "I10", color: "green", days_ago: 50,
      to: "authorized", offer: :own,
      justification: "Hipertenso e diabético há mais de dez anos, com sopro sistólico em foco aórtico ao exame. Solicito " \
                     "avaliação cardiológica e ecocardiograma." },
    { n: 7, who: :valdir, type: "specialty", code: OPHTHALMOLOGY, cid10: "H40", color: "yellow", days_ago: 25, to: "scheduled",
      offer: :contracted, schedule_in: 12.days,
      justification: "Pressão intraocular elevada na aferição (26 mmHg à direita) com escavação aumentada do disco óptico; " \
                     "história familiar de glaucoma." },
    { n: 8, who: :cristiane, type: "procedure", code: ENDOSCOPY, cid10: "K21", color: "green", days_ago: 15, to: "returned",
      return_reason: "Informar se há sinais de alarme (disfagia, perda de peso, sangramento) e o tratamento já feito.",
      justification: "Pirose e regurgitação há oito meses, sem resposta a omeprazol 40 mg por oito semanas. Solicito " \
                     "endoscopia digestiva alta." },
    { n: 9, who: :leonardo, type: "specialty", code: ORTHOPEDICS, cid10: "M54", color: "blue", days_ago: 30, to: "external",
      state_regulated: true, external: { system: "sisreg", number: "202610280001" },
      justification: "Lombalgia crônica mecânica há um ano, sem sinais de alarme nem déficit neurológico. Avaliação ortopédica " \
                     "eletiva regulada pelo estado." },
    { n: 10, who: :sebastiao, care_lines: true, type: "specialty", code: OPHTHALMOLOGY, cid10: "H25", color: "green",
      days_ago: 45, to: "completed", offer: :contracted,
      justification: "Catarata senil bilateral com baixa visual que limita as atividades diárias; avaliação para facectomia." }
  ].freeze
  SCHEDULE = { place: "Clínica de Olhos Araucária — R. Emiliano Perneta, 390, Centro",
               notes: "Levar documento com foto e os óculos em uso." }.freeze
  VISIT = { "subjective" => "Queixa descrita no pedido de regulação.", "objective" => "Bom estado geral.",
            "assessment" => "Encaminhamento à atenção especializada.", "plan" => "Pedido de regulação; retorno com a contrarreferência.",
            "vitals" => { "systolic" => 134, "diastolic" => 84, "weight_kg" => "76.0", "height_cm" => 168 },
            "care_type" => 5, "conducts" => [ 1 ], "exam_requests" => [] }.freeze

  class << self
    include ActiveSupport::Testing::TimeHelpers

    # A SIGTAP de dev com os reguláveis (competência corrente e anterior) e a
    # CID-10 de dev com os diagnósticos dos pedidos. Release real: não toca.
    def seed_platform!
      guard_environment!
      { sigtap: sigtap!, cid10: cid10! }
    end

    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] regulação: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: CareRegulation::Gate::KEY, enabled: true, maintainer: maintainer)
      RegulationRiskDeadline.ensure_defaults!
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      regulator = regulator!(slug, password)
      providers = providers!(admin)
      offers = offers!(providers, admin)
      nurse_items!(admin)

      clock = Time.current
      unit = HealthUnit.find_by!(name: UNIT)
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      REQUESTS.each do |spec|
        request = request!(slug, ddd, spec, unit, doctor, clock)
        advance!(request, spec, regulator, offers, clock)
      end

      { switch: CareRegulation::Gate.usable?(city) ? "ligado (care_regulation)" : "ligado, não utilizável",
        providers: providers.size, offers: offers.size, requests: counts,
        users: [ { email: regulator.email_address, role: REGULATOR[:role], otpauth_uri: SignatureCrew.otpauth_uri(regulator) } ] }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel e otpauth (nunca dado de paciente).
    def summary_lines(result, password:)
      lines = [ "[seeds] regulação .. #{result[:switch]}" \
                "#{"; #{result[:providers]} prestadores, #{result[:offers]} ofertas; pedidos #{result[:requests].map { |k, v| "#{k} #{v}" }.join(', ')}" if result[:requests].any?}" ]
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    # CPF da pessoa nova (dígitos válidos, estáveis pela semente).
    def cpf_for(slug, key) = ScreeningCrew.send(:cpf_for, "#{slug}:regulation:#{key}")

    def phone_for(ddd, key) = format("+55%s#{PHONE_PREFIX}%04d", ddd, PEOPLE.fetch(key)[:phone])

    # O pedido da semente (pessoa × alvo), ou nil.
    def request_of(slug, spec)
      patient_id = citizen_of(slug, spec)&.patient_id
      return nil unless patient_id

      RegulationRequest.where(patient_id: patient_id, target_type: spec[:type], target_code: spec[:code])
                       .order(:created_at, :id).first
    end

    private

    def guard_environment!
      raise "semente da regulação: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, providers: 0, offers: 0, requests: {}, users: [] }

    def counts = RegulationRequest.where.not(status: "draft").group(:status).count.sort.to_h

    def at(time, clock, &) = travel_to([ time, clock - 1.second ].min, &)

    def day_at(clock, days_ago, hour) = (clock.to_date - days_ago).in_time_zone.change(hour: hour)

    # --- plataforma -----------------------------------------------------

    def real_sigtap_active?
      TerminologyRelease.active.where(kind: "sigtap").pluck(:id).any? do |id|
        SigtapProcedure.where(release_id: id).count > SigtapSample::PROCEDURES.size
      end
    end

    def sigtap!
      today = Time.zone.today
      competences = [ (today << 1).strftime("%Y%m"), today.strftime("%Y%m") ]
      return { competences: competences, status: :real_sigtap } if real_sigtap_active?

      codes = SigtapSample::REGULATION_CODES
      imported = competences.select do |competence|
        release = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
        next false if release && SigtapProcedureInstrument.where(release_id: release.id, procedure_code: codes).distinct.count(:procedure_code) == codes.size

        Dir.mktmpdir do |dir|
          result = Terminology::Import.call(kind: "sigtap", version: competence, path: SigtapSample.write_to(dir, competence: competence), by: "db:seed")
          raise "semente da regulação: SIGTAP recusada (#{result.reason} #{result.message})" if result.failure?
        end
        true
      end
      { competences: competences, status: imported.any? ? :republished : :complete }
    end

    # Republica o recorte "dev-*" ativo com os códigos que ele já tem mais os
    # diagnósticos dos pedidos; uma release real ativa nunca é tocada.
    def cid10!
      return :complete if CID10.keys.all? { |code| ClinicalTerms.find("cid10", code) }

      active = ClinicalTerms.release("cid10")
      unless active&.version.to_s.start_with?("dev-")
        warn "[seeds] regulação: CID-10 ativa não é o recorte de dev — diagnósticos dos pedidos não republicados"
        return :real_cid10
      end

      codes = Cid10Code.where(release_id: active.id).pluck(:code, :description, :sex_restriction)
                       .to_h { |code, description, sex| [ code, [ description, sex ] ] }
                       .merge(CID10.transform_values { |description| [ description, nil ] }) { |_code, old, _new| old }
      Dir.mktmpdir do |dir|
        write_cid10(Pathname(dir), codes)
        result = Terminology::Import.call(kind: "cid10", version: CID10_VERSION, path: dir, by: "db:seed")
        raise "semente da regulação: CID-10 recusada (#{result.reason} #{result.message})" if result.failure?
      end
      :republished
    end

    def write_cid10(dir, codes)
      categories, subcategories = codes.partition { |code, _| code.length == 3 }
      dir.join("CID-10-CATEGORIAS.CSV").binwrite(("CAT;DESCRICAO\n" + categories.map { |c, (d, _)| "#{c};#{d}" }.join("\n") + "\n").encode("ISO-8859-1"))
      dir.join("CID-10-SUBCATEGORIAS.CSV").binwrite(("SUBCAT;DESCRICAO;RESTRSEXO\n" +
        subcategories.map { |c, (d, sex)| "#{c};#{d};#{sex}" }.join("\n") + "\n").encode("ISO-8859-1"))
    end

    # --- configuração da cidade -------------------------------------------

    def regulator!(slug, password)
      user = User.find_or_initialize_by(email_address: "#{REGULATOR[:email_prefix]}@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: REGULATOR[:role]) { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: REGULATOR[:secret_env], default_secret: REGULATOR[:default_secret])
      user.reload
    end

    def dev_cnes(name) = format("%07d", (Zlib.crc32("care-provider:#{name}") % 9_000_000) + 1_000_000)

    def own_unit!
      HealthUnit.find_or_create_by!(name: OWN_UNIT) do |unit|
        unit.kind = "other"
        unit.cnes = dev_cnes(OWN_UNIT)
      end
    end

    # Prestadores pelo SaveProvider (a própria com a unidade e o CNES dela).
    def providers!(admin)
      PROVIDERS.transform_values do |spec|
        existing = CareProvider.find_by(name: spec[:name])
        next existing if existing

        attrs = { "name" => spec[:name], "kind" => spec[:kind] }
        attrs.merge!(spec[:kind] == "own" ? { "health_unit_id" => own_unit!.id } : { "cnes" => dev_cnes(spec[:name]) })
        saved = CareRegulation::SaveProvider.call(attrs: attrs, by: admin)
        raise "semente da regulação: prestador #{spec[:kind]} recusado (#{saved.reason} #{saved.details})" if saved.failure?

        saved.payload.fetch(:provider)
      end
    end

    # Ofertas do mês corrente pelo SaveOffer.
    def offers!(providers, admin)
      month = Time.zone.today.beginning_of_month
      OFFERS.to_h do |spec|
        provider = providers.fetch(spec[:provider])
        offer = CareOffer.find_by(care_provider_id: provider.id, target_type: spec[:type], target_code: spec[:code], month: month)
        unless offer
          saved = CareRegulation::SaveOffer.call(attrs: { "provider_id" => provider.id, "target_type" => spec[:type], "target_code" => spec[:code],
                                                          "month" => month.strftime("%Y-%m"), "quantity" => spec[:quantity] }, by: admin)
          raise "semente da regulação: oferta #{spec[:code]} recusada (#{saved.reason} #{saved.details})" if saved.failure?

          offer = saved.payload.fetch(:offer)
        end
        [ spec[:provider], offer ]
      end
    end

    def nurse_items!(admin)
      NURSE_ITEMS.each do |code|
        next if NurseRequestableItem.exists?(target_type: "specialty", target_code: code)

        added = CareRegulation::NurseItems.add(target_type: "specialty", target_code: code, by: admin)
        raise "semente da regulação: item do enfermeiro #{code} recusado (#{added.reason})" if added.failure?
      end
    end

    # --- pessoas e pedidos ------------------------------------------------

    def citizen_of(slug, spec)
      cpf = spec[:care_lines] ? CareLinesCrew.cpf_for(slug, spec[:who]) : cpf_for(slug, spec[:who])
      Citizen.find_by(cpf: cpf)
    end

    def citizen!(slug, ddd, spec)
      if spec[:care_lines]
        citizen = citizen_of(slug, spec)
        raise "semente da regulação: #{spec[:who]} ausente — rode o CareLinesCrew (db:seed) antes" unless citizen&.verification_level_verified?

        return citizen
      end

      key = spec[:who]
      person = PEOPLE.fetch(key)
      registered = Citizens::RegisterPerson.call(phone: phone_for(ddd, key), cpf: cpf_for(slug, key),
                                                 profile: { birth_date: person[:birth], sex: person[:sex], gender_identity: nil })
      raise "semente da regulação: pessoa #{key} recusada (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      unless citizen.verification_level_verified?
        reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
        code = Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
        verified = Citizens::Verify.call(cpf: citizen.cpf, code: code, document_checked: true, by: reception, birth_date: person[:birth],
                                         sex: person[:sex], full_name: person[:name], mother_name: person[:mother])
        raise "semente da regulação: validação #{key} recusada (#{verified.reason})" if verified.failure?
      end
      citizen.reload
    end

    # O pedido existente é retomado (um rascunho sobrevivente é finalizado);
    # senão, a consulta da médica naquele dia, com o rascunho de regulação, e a
    # finalização que o promove.
    def request!(slug, ddd, spec, unit, doctor, clock)
      citizen = citizen!(slug, ddd, spec)
      existing = request_of(slug, spec)
      return finalize!(existing.consultation, doctor, day_at(clock, spec[:days_ago], 11), clock, spec) if existing&.status == "draft"
      return existing if existing

      start = day_at(clock, spec[:days_ago], 8 + (spec[:n] % 3))
      attendance = at(start, clock) { ClinicalRecordCrew.send(:checked_in!, slug, unit, citizen, "regulacao-#{spec[:n]}") }
      called = at(start + 20.minutes, clock) { Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: doctor) }
      raise "semente da regulação: chamada do pedido #{spec[:n]} recusada (#{called.reason})" if called.failure?

      started = at(start + 21.minutes, clock) { Consultations::Start.call(attendance: attendance.reload, by: doctor) }
      raise "semente da regulação: consulta do pedido #{spec[:n]} recusada (#{started.reason})" if started.failure?

      consultation = started.payload.fetch(:consultation)
      attrs = { "type" => spec[:type], "target_code" => spec[:code], "cid10" => spec[:cid10], "justification" => spec[:justification],
                "suggested_color" => spec[:color], "state_regulated" => spec.fetch(:state_regulated, false) }
      drafted = at(start + 30.minutes, clock) { CareRegulation::SaveDraft.call(consultation: consultation, attrs: attrs, by: doctor) }
      raise "semente da regulação: rascunho do pedido #{spec[:n]} recusado (#{drafted.reason} #{drafted.details})" if drafted.failure?

      visit = VISIT.merge("evaluated_problems" => [ { "terminology" => "cid10", "code" => spec[:cid10], "action" => "add" } ])
      saved = at(start + 31.minutes, clock) { Consultations::SaveDraft.call(consultation: consultation.reload, params: visit, by: doctor) }
      raise "semente da regulação: consulta do pedido #{spec[:n]} recusada (#{saved.reason} #{saved.details})" if saved.failure?

      finalize!(consultation, doctor, start + 35.minutes, clock, spec)
    end

    def finalize!(consultation, doctor, time, clock, spec)
      finalized = at(time, clock) do
        Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
      end
      raise "semente da regulação: finalização do pedido #{spec[:n]} recusada (#{finalized.reason} #{finalized.details})" if finalized.failure?

      request = RegulationRequest.find_by!(consultation_id: consultation.id, target_code: spec[:code])
      raise "semente da regulação: pedido #{spec[:n]} não promovido" if request.status == "draft"

      request
    end

    # Retoma o pedido do estado em que está até a situação da tabela. Um
    # pedido que saiu do caminho (cancelado na prova, por exemplo) fica como está.
    def advance!(request, spec, regulator, offers, clock)
      timing = completion_times(clock) if spec[:to] == "completed"
      loop do
        request.reload
        case [ request.status, spec[:to] ]
        in [ "external", "external" ]
          mark_external!(request, spec, regulator) if request.external_number.nil?
          break
        in [ "pending", "returned" ]
          returned = at(request.requested_at + 2.days, clock) do
            CareRegulation::Decide.call(request: request, decision: "return", reason: spec[:return_reason], version: request.version, by: regulator)
          end
          check!(returned, spec, "devolução")
        in [ "pending", "authorized" | "scheduled" ]
          check!(authorize!(request, spec, regulator, offers), spec, "autorização")
        in [ "pending", "completed" ]
          check!(at(timing[:authorized], clock) { authorize!(request, spec, regulator, offers) }, spec, "autorização")
        in [ "authorized", "scheduled" ]
          check!(schedule!(request, spec, regulator, (clock + spec[:schedule_in]).change(hour: 14, min: 30)), spec, "agendamento")
        in [ "authorized", "completed" ]
          scheduled = at(timing[:scheduled], clock) { schedule!(request, spec, regulator, timing[:appointment]) }
          check!(scheduled, spec, "agendamento")
        in [ "scheduled", "completed" ]
          done = CareRegulation::RecordOutcome.call(request: request, result: "completed", version: request.version, by: regulator)
          check!(done, spec, "desfecho")
        else
          break
        end
      end
    end

    # Pedido 10: autorizado há até 6 dias (dentro do mês corrente: a oferta é
    # a do mês), marcado um minuto depois para o meio do intervalo e atendido.
    def completion_times(clock)
      authorized = [ [ clock - 6.days, Time.zone.today.beginning_of_month.in_time_zone + 1.minute ].max, clock - 3.minutes ].min
      { authorized: authorized, scheduled: authorized + 1.minute,
        appointment: (authorized + ((clock - authorized) / 2)).change(sec: 0) }
    end

    # Cor confirmada (igual à sugerida): sem motivo de mudança.
    def authorize!(request, spec, regulator, offers)
      CareRegulation::Authorize.call(request: request, offer_id: offers.fetch(spec[:offer]).id, version: request.version, by: regulator,
                                     color: spec[:color])
    end

    def schedule!(request, _spec, regulator, time)
      CareRegulation::ScheduleExternal.call(request: request, at: time.iso8601, place: SCHEDULE[:place], notes: SCHEDULE[:notes],
                                            version: request.version, by: regulator)
    end

    def mark_external!(request, spec, regulator)
      marked = CareRegulation::MarkExternal.call(request: request, system: spec[:external][:system], number: spec[:external][:number],
                                                 version: request.version, by: regulator)
      check!(marked, spec, "marcação no sistema do estado")
    end

    def check!(result, spec, what)
      raise "semente da regulação: #{what} do pedido #{spec[:n]} recusada (#{result.reason} #{result.details})" if result.failure?
    end
  end
end
