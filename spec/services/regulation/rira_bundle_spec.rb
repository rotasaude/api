require "rails_helper"
require "zlib"
require "rubygems/package"

# Módulo 26c, Task 8 (Valores 7, 8 e 9; Q6, Q12, Q15, Q18; pré-voo B4, I6, I7,
# I9, M16–M18): o documento RIRA montado dos fatos, a impressão digital e o
# esqueleto. A montagem é pura sobre `RiraFacts`; os fatos do banco vêm dos
# comandos reais da 26a e do 17. CPF e CNS são os fictícios dos helpers.
RSpec.describe Regulation::RiraBundle, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }
  let(:profile) { Regulation::RiraProfile.current }
  let(:sync_row) { sync_double }
  let(:cpf) { valid_cpf(901) }

  def sync_double(last_rnds_id: nil, bundle_identifier: "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b")
    Struct.new(:bundle_identifier, :last_rnds_id, keyword_init: true).new(bundle_identifier: bundle_identifier, last_rnds_id: last_rnds_id)
  end

  def facts(**over)
    Regulation::RiraFacts.new(**{
      patient_cpf: cpf, patient_cns: nil, requester_cnes: "2345678", author_cnes: "1234567", requester_id: "2926",
      target_type: "specialty", target_code: "225120", sigtap: "0301010072", sigtap_valid: true,
      performer_cnes: "3456789", performer_cbo: "225120", priority: "routine", cid10: "I10", ciap2: nil,
      requested_at: now - 10.days, authorized_at: now - 5.days, scheduled_at: now + 3.days, absence_times: [],
      status_times: { "pending" => now - 10.days }, own_network: true
    }.merge(over))
  end

  def target(status, at: now - 1.day) = Regulation::RndsStatus::Target.new(status: status, at: at)

  def build(f = facts, status: target("pending"), sync: sync_row, at: now)
    Regulation::RiraBundle.build(facts: f, sync: sync, status: status, now: at)
  end

  def res(bundle, type) = bundle.fetch("entry").map { |e| e["resource"] }.find { |r| r["resourceType"] == type }
  def code_of(node) = node.dig("coding", 0, "code")

  describe ".build (puro)" do
    it "o pending tem 4 entradas na ordem, Appointment proposed, ServiceRequest active/proposal, sem performer" do
      bundle = build(facts(scheduled_at: nil))
      expect(bundle).to include("resourceType" => "Bundle", "type" => "document")
      expect(bundle["entry"].map { |e| e.dig("resource", "resourceType") }).to eq(%w[Composition Appointment ServiceRequest Condition])
      expect(bundle["entry"].map { |e| e["fullUrl"] }).to all(match(/\Aurn:uuid:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/))
      expect(res(bundle, "Appointment")).to include("status" => "proposed")
      expect(res(bundle, "Appointment")).not_to include("start")
      expect(res(bundle, "ServiceRequest")).to include("status" => "active", "intent" => "proposal")
      expect(res(bundle, "ServiceRequest")).not_to include("performer")
      composition = res(bundle, "Composition")
      expect(code_of(composition.dig("event", 0, "code", 0))).to eq("pending")
      expect(composition.dig("section", 0, "entry", 0, "reference")).to eq(bundle.dig("entry", 1, "fullUrl"))
      expect(res(bundle, "Appointment").dig("basedOn", 0, "reference")).to eq(bundle.dig("entry", 2, "fullUrl"))
      expect(res(bundle, "ServiceRequest").dig("reasonReference", 0, "reference")).to eq(bundle.dig("entry", 3, "fullUrl"))
    end

    it "o fullUrl é novo a cada montagem" do
      expect(build["entry"].map { |e| e["fullUrl"] }).not_to eq(build["entry"].map { |e| e["fullUrl"] })
    end

    it "cada situação usa o par do STATUS_RELATION e põe a situação no event com o period.end" do
      Regulation::RndsCatalog::STATUS_RELATION.each do |status, (appointment_status, request_status)|
        bundle = build(status: target(status, at: now - 2.hours))
        event = res(bundle, "Composition").dig("event", 0)
        expect(event.dig("code", 0, "coding", 0)).to eq("system" => profile.code_systems[:status], "code" => status)
        expect(event.dig("period", "end")).to eq((now - 2.hours).iso8601)
        expect(res(bundle, "Appointment")["status"]).to eq(appointment_status), status
        expect(res(bundle, "ServiceRequest")["status"]).to eq(request_status), status
      end
    end

    it "a situação também vem como passo { status, at } ou só o código (instante dos fatos)" do
      step = build(status: { "status" => "pending", "at" => (now - 3.hours).iso8601 })
      expect(res(step, "Composition").dig("event", 0, "period", "end")).to eq((now - 3.hours).iso8601)
      bare = build(status: "pending")
      expect(res(bare, "Composition").dig("event", 0, "period", "end")).to eq((now - 10.days).iso8601)
    end

    it "cada entrada declara o seu perfil (I6) e o Bundle.timestamp é o now" do
      bundle = build
      expect(bundle["timestamp"]).to eq(now.iso8601)
      expect(bundle["entry"].map { |e| e.dig("resource", "meta", "profile") })
        .to eq(profile.profiles.values_at(:composition, :appointment, :service_request, :condition).map { |url| [ url ] })
    end

    it "Composition: final, RA, categoria 09, título, data AAAA-MM-DD (date-1), autor = CNES da credencial" do
      composition = res(build, "Composition")
      expect(composition).to include("status" => "final", "title" => "Regulação Assistencial", "date" => "2026-11-20")
      expect(composition["type"]).to eq("coding" => [ { "system" => profile.code_systems[:document_type], "code" => "RA" } ])
      expect(composition["category"]).to eq([ { "coding" => [ { "system" => profile.code_systems[:modality], "code" => "09" } ] } ])
      expect(composition["author"]).to eq([ { "identifier" => { "system" => profile.identifiers[:establishment], "value" => "1234567" } } ])
    end

    it "nenhum custodian nem section.title" do
      composition = res(build, "Composition")
      expect(composition).not_to include("custodian")
      expect(composition["section"]).to all(satisfy { |section| !section.key?("title") })
    end

    it "Bundle.identifier.system termina em BRRNDS-<requester_id> e o value é o bundle_identifier" do
      expect(build["identifier"]).to eq("system" => "#{profile.identifiers[:requester_prefix]}2926",
                                        "value" => "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b")
      expect(build["identifier"]["system"]).to end_with("BRRNDS-2926")
    end

    it "com last_rnds_id há relatesTo Composition/<id>; sem ele, não" do
      expect(res(build, "Composition")).not_to include("relatesTo")
      replacing = build(sync: sync_double(last_rnds_id: "abc-123"))
      expect(res(replacing, "Composition")["relatesTo"])
        .to eq([ { "code" => "replaces", "targetReference" => { "reference" => "Composition/abc-123" } } ])
    end

    it "booked: start = scheduled_at, authoredOn = requested_at, created = autorização, executante e CBO" do
      bundle = build(status: target("booked"))
      appointment = res(bundle, "Appointment")
      request = res(bundle, "ServiceRequest")
      expect(appointment).to include("status" => "booked", "start" => (now + 3.days).iso8601, "created" => (now - 5.days).iso8601)
      expect(appointment["serviceCategory"]).to eq([ { "coding" => [ { "system" => profile.code_systems[:modality], "code" => "09" } ] } ])
      expect(appointment["serviceType"]).to eq([ { "coding" => [ { "system" => profile.code_systems[:sigtap], "code" => "0301010072" } ] } ])
      expect(appointment["specialty"]).to eq([ { "coding" => [ { "system" => profile.code_systems[:cbo], "code" => "225120" } ] } ])
      expect(appointment["appointmentType"]).to eq("coding" => [ { "system" => profile.priority_system, "code" => "routine" } ])
      expect(appointment["participant"]).to eq([ { "type" => [ { "coding" => [ { "system" => profile.code_systems[:participant_type], "code" => "PCT" } ] } ],
                                                   "actor" => { "identifier" => { "system" => profile.identifiers[:individual], "value" => cpf } },
                                                   "status" => "accepted" } ])
      expect(request).to include("authoredOn" => (now - 10.days).iso8601, "priority" => "routine")
      expect(request["code"]).to eq("coding" => [ { "system" => profile.code_systems[:sigtap], "code" => "0301010072" } ])
      expect(request["requester"]).to eq("identifier" => { "system" => profile.identifiers[:establishment], "value" => "2345678" })
      expect(request["performer"]).to eq([ { "identifier" => { "system" => profile.identifiers[:establishment], "value" => "3456789" } } ])
      expect(request["performerType"]).to eq("coding" => [ { "system" => profile.code_systems[:cbo], "code" => "225120" } ])
    end

    it "attended leva o executante; cancelled, returned e excluded, não; nenhum leva data fora de booked/attended/absence" do
      expect(res(build(status: target("attended")), "ServiceRequest")).to include("performer")
      %w[cancelled returned-to-requester excluded pending].each do |status|
        bundle = build(status: target(status))
        expect(res(bundle, "ServiceRequest")).not_to include("performer")
        expect(res(bundle, "Appointment")).not_to include("start")
      end
    end

    it "absence (Q18): start = o horário no_show/expired até a falta; externo vai sem data; sem executante (I7)" do
      first = now - 20.days
      second = now - 4.days
      own = facts(absence_times: [ first, second ])
      step = build(own, status: { "status" => "absence", "at" => (first + 1.day).iso8601 })
      expect(res(step, "Appointment")).to include("status" => "noshow", "start" => first.iso8601)
      final = build(own, status: target("absence", at: now))
      expect(res(final, "Appointment")["start"]).to eq(second.iso8601)
      expect(res(final, "ServiceRequest")).to include("status" => "completed")
      expect(res(final, "ServiceRequest")).not_to include("performer")
      external = build(facts(own_network: false, absence_times: []), status: target("absence"))
      expect(res(external, "Appointment")).not_to include("start")
    end

    it "CID-10 tem precedência sobre CIAP-2; sem CID, o CIAP-2" do
      both = res(build(facts(cid10: "I10", ciap2: "K86")), "Condition")
      expect(both["code"]).to eq("coding" => [ { "system" => profile.code_systems[:cid10], "code" => "I10" } ])
      expect(both["clinicalStatus"]).to eq("coding" => [ { "system" => profile.code_systems[:condition_clinical], "code" => "active" } ])
      ciap = res(build(facts(cid10: nil, ciap2: "K86")), "Condition")
      expect(ciap["code"]).to eq("coding" => [ { "system" => profile.code_systems[:ciap2], "code" => "K86" } ])
    end

    it "paciente só com CNS → identifier com o CNS (mesmo system BRIndividuo-1.0, M18) nos quatro recursos" do
      cns = valid_cns(901)
      bundle = build(facts(patient_cpf: nil, patient_cns: cns))
      expected = { "system" => profile.identifiers[:individual], "value" => cns }
      expect(res(bundle, "Composition").dig("subject", "identifier")).to eq(expected)
      expect(res(bundle, "Appointment").dig("participant", 0, "actor", "identifier")).to eq(expected)
      expect(res(bundle, "ServiceRequest").dig("subject", "identifier")).to eq(expected)
      expect(res(bundle, "Condition").dig("subject", "identifier")).to eq(expected)
      expect(res(build, "Composition").dig("subject", "identifier", "value")).to eq(cpf)
    end

    it "nunca levanta por fato ausente (I9): sem credencial some o system e o autor, e o esqueleto acusa" do
      empty = facts(**facts.to_h.keys.index_with { nil }.merge(target_type: "specialty", sigtap: "0301010072"))
      expect { build(empty, status: target("booked")) }.not_to raise_error
      bundle = build(facts(requester_id: nil, author_cnes: nil))
      expect(bundle["identifier"]).to eq("value" => "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b")
      expect(Regulation::RiraSkeleton.problems(bundle)).to eq(%w[Bundle.identifier.system Composition.author.identifier.value])
    end

    it "sem cor (Q15), o caráter some e o esqueleto acusa priority e appointmentType" do
      problems = Regulation::RiraSkeleton.problems(build(facts(priority: nil)))
      expect(problems).to include("Appointment.appointmentType.coding.system", "ServiceRequest.priority")
    end
  end

  describe ".digest" do
    let(:base) { described_class.digest(build(status: target("booked"))) }

    it "é SHA-256 hex e igual com outro now, outro last_rnds_id, outro fullUrl e sem credencial" do
      expect(base).to match(/\A\h{64}\z/)
      expect(described_class.digest(build(status: target("booked"), at: now + 2.days))).to eq(base)
      expect(described_class.digest(build(status: target("booked"), sync: sync_double(last_rnds_id: "x1")))).to eq(base)
      expect(described_class.digest(build(facts(requester_id: nil, author_cnes: nil), status: target("booked")))).to eq(base)
      expect(described_class.digest(build(status: target("booked"), sync: sync_double(bundle_identifier: "outro")))).to eq(base)
    end

    it "muda com a remarcação, a cor, o CID, o CNES e a situação" do
      changed = [
        facts(scheduled_at: now + 4.days), facts(priority: "urgent"), facts(cid10: "E11"),
        facts(performer_cnes: "4567890"), facts(requester_cnes: "5678901")
      ].map { |f| described_class.digest(build(f, status: target("booked"))) }
      expect(changed).to all(satisfy { |digest| digest != base })
      expect(described_class.digest(build(status: target("attended")))).not_to eq(base)
    end
  end

  describe Regulation::RiraSkeleton do
    def package_elements
      @package_elements ||= Zlib::GzipReader.open(Rails.root.join("spec/fixtures/rira/br.gov.saude.rira.fhir-1.0.0-release.tgz")) do |gz|
        files = {}
        Gem::Package::TarReader.new(gz).each do |e|
          next unless e.file? && File.basename(e.full_name).match?(/\AStructureDefinition-.*\.json\z/)

          sd = JSON.parse(e.read)
          files[sd["url"]] = sd.dig("snapshot", "element")
        end
        files
      end
    end

    # { caminho sem fatias => mín } e os caminhos de presença obrigatória
    # (mín. >= 1 com todos os ancestrais também obrigatórios), por perfil.
    def required_paths(url)
      elements = package_elements.fetch(url)
      mins = elements.to_h { |e| [ e["id"].gsub(/:[^.]+/, ""), [ e["min"].to_i, mins_of(elements, e["id"].gsub(/:[^.]+/, "")) ].max ] }
      required = mins.select do |path, min|
        parts = path.split(".")
        min >= 1 && parts.size > 1 && (2...parts.size).all? { |k| mins.fetch(parts.first(k).join("."), 1) >= 1 }
      end
      [ mins, required.keys ]
    end

    def mins_of(elements, path) = elements.select { |e| e["id"].gsub(/:[^.]+/, "") == path }.map { |e| e["min"].to_i }.max

    it "os caminhos do esqueleto são exatamente os obrigatórios dos quatro perfis do pacote" do
      Regulation::RiraSkeleton::REQUIRED.each do |type, paths|
        key = { "Composition" => :composition, "Appointment" => :appointment, "ServiceRequest" => :service_request,
                "Condition" => :condition }.fetch(type)
        mins, required = required_paths(profile.profiles.fetch(key))
        full = paths.map { |path| "#{type}.#{path}" }
        full.each { |path| expect(mins.fetch(path, 0)).to be >= 1, path }
        # todo obrigatório do perfil é um caminho do esqueleto ou o prefixo de um
        required.each { |path| expect(full.any? { |p| p == path || p.start_with?("#{path}.") }).to be(true), path }
      end
    end

    it "problems vazio em todas as situações, rede própria e externa, CPF ou CNS, CID ou CIAP" do
      variants = [ facts, facts(own_network: false, absence_times: []), facts(patient_cpf: nil, patient_cns: valid_cns(902)),
                   facts(cid10: nil, ciap2: "K86"), facts(performer_cbo: nil) ]
      variants.product(Regulation::RndsCatalog::MIRA_STATUSES).each do |f, status|
        expect(described_class.problems(build(f, status: target(status)))).to eq([]), status
      end
      expect(described_class.problems(build(sync: sync_double(last_rnds_id: "r1")))).to eq([])
    end

    it "acusa o caminho ausente, nunca o valor" do
      bundle = build
      bundle["entry"][2]["resource"].delete("requester")
      bundle["entry"][3]["resource"].delete("code")
      problems = described_class.problems(bundle)
      expect(problems).to eq(%w[ServiceRequest.requester.identifier.system ServiceRequest.requester.identifier.value
                                Condition.code.coding.system Condition.code.coding.code])
      expect(problems.join).not_to include(cpf)
      expect(described_class.problems(bundle.merge("entry" => bundle["entry"].first(2)))).to eq(%w[Bundle.entry.ServiceRequest Bundle.entry.Condition])
    end
  end

  describe "fatos lidos do banco (RiraFacts.for)" do
    let(:settings) { RegulationRndsSetting.current }
    let(:regulator) { regulation_regulator! }

    before do
      travel_to now
      regulation_city!
      tick_regulation_events!
    end

    def requester_unit = (@requester_unit ||= create_unit("UBS Solicitante #{SecureRandom.hex(2)}", cnes: regulation_cnes))
    def read(request, credential: nil) = Regulation::RiraFacts.for(request: request.reload, settings: settings.reload, credential: credential)

    def own_booked!(type: "procedure", code: "0401010074", cbo: "225250", shift: true)
      unit = create_unit("Centro de Especialidades #{SecureRandom.hex(3)}", cnes: regulation_cnes)
      provider = own_provider!(unit)
      offer = offer!(provider: provider, target_type: type, target_code: code)
      request = reauthorize!(regulation_request!(type: type, target_code: code, unit: requester_unit), offer: offer)
      appointment_request = AppointmentRequest.find(request.appointment_request_id)
      at = (now + 3.days).change(hour: 9)
      appointment = if shift
                      link = doctor_link!(unit, cbo: cbo)
                      appointment_row!(appointment_request, shift!(link, starts_at: at - 1.hour), starts_at: at)
                    else
                      schedule_regulated!(appointment_request, at: at)
                    end
      CareRegulation::AppointmentSync.call(appointment_request_id: appointment_request.id) unless shift
      { request: request.reload, appointment: appointment, unit: unit, offer: offer, provider: provider }
    end

    def schedule_external!(request, provider:, at: now + 3.days)
      result = CareRegulation::ScheduleExternal.call(request: request.reload, at: at.iso8601, place: "Hospital Regional", notes: nil,
                                                     version: request.version, by: regulator, care_provider_id: provider.id)
      raise "agendamento recusado: #{result.reason}" if result.failure?

      request.reload
    end

    it "lê a unidade solicitante, o paciente e a credencial; sem credencial, requester_id e author_cnes nulos" do
      request = regulation_request!(unit: requester_unit)
      credential = rnds_regulation_credential!(cnes: "7654321", requester_id: "2926")
      read_facts = read(request, credential: credential)
      expect(read_facts).to have_attributes(requester_cnes: requester_unit.cnes, author_cnes: "7654321", requester_id: "2926",
                                            patient_cpf: request.patient.cpf, target_type: "specialty", target_code: "225120",
                                            cid10: "I10", requested_at: request.requested_at, own_network: true)
      expect(read(request)).to have_attributes(author_cnes: nil, requester_id: nil)
      expect(described_class.digest(described_class.build(facts: read(request), sync: sync_row, status: target("pending"), now: now)))
        .to eq(described_class.digest(described_class.build(facts: read_facts, sync: sync_row, status: target("pending"), now: now)))
    end

    it "inspect, to_s e as_json não mostram CPF, CID nem o identificador do solicitante" do
      request = regulation_request!(unit: requester_unit)
      read_facts = read(request, credential: rnds_regulation_credential!(requester_id: "2926"))
      [ read_facts.inspect, read_facts.to_s, read_facts.as_json.to_json, PP.pp(read_facts, +"") ].each do |text|
        expect(text).not_to include(request.patient.cpf, "I10", "2926")
      end
    end

    it "vermelho → urgent; amarelo → routine; a cidade troca amarelo para urgent e o documento segue" do
      yellow = regulation_request!(unit: requester_unit, suggested_color: "yellow")
      expect(read(yellow).priority).to eq("routine")
      red = regulation_request!(unit: requester_unit, suggested_color: "yellow")
      authorized = CareRegulation::Authorize.call(request: red, offer_id: offer!(provider: external_provider!).id, version: red.version,
                                                  by: regulator, color: "red", color_reason: "Piora clínica relatada no retorno")
      raise "autorização recusada: #{authorized.reason}" if authorized.failure?

      bundle = described_class.build(facts: read(red), sync: sync_row, status: target("pending"), now: now)
      expect(res(bundle, "ServiceRequest")["priority"]).to eq("urgent")
      expect(res(bundle, "Appointment").dig("appointmentType", "coding", 0, "code")).to eq("urgent")
      settings.update!(priority_by_color: settings.priority_by_color.merge("yellow" => "urgent"))
      expect(res(described_class.build(facts: read(yellow), sync: sync_row, status: target("pending"), now: now), "ServiceRequest")["priority"])
        .to eq("urgent")
    end

    it "pendente sem cor decidida usa a sugerida (B4)" do
      request = regulation_request!(unit: requester_unit, suggested_color: "red")
      expect(request.color).to be_nil
      expect(read(request).priority).to eq("urgent")
    end

    it "especialidade sem entrada → 0301010072 e performerType = CBO do alvo; com entrada → o SIGTAP configurado" do
      request = regulation_request!(unit: requester_unit)
      bundle = described_class.build(facts: read(request), sync: sync_row, status: target("pending"), now: now)
      expect(code_of(res(bundle, "ServiceRequest")["code"])).to eq("0301010072")
      expect(code_of(res(bundle, "ServiceRequest")["performerType"])).to eq("225120")
      expect(read(request).sigtap_valid).to be(true)
      settings.update!(specialty_sigtap: { "225120" => "0209010037" })
      expect(read(request)).to have_attributes(sigtap: "0209010037", sigtap_valid: true)
    end

    it "pedido por especialidade agendado: o CBO do executante é o do alvo, mesmo com outro CBO no turno (Q12)" do
      booked = own_booked!(type: "specialty", code: "225120", cbo: "225250")
      expect(booked[:appointment].shift.professional_link.cbo_code).to eq("225250")
      expect(read(booked[:request])).to have_attributes(performer_cbo: "225120", performer_cnes: booked[:unit].cnes, own_network: true)
    end

    it "booked por procedimento na rede própria: CNES da unidade do horário, CBO do vínculo do turno" do
      booked = own_booked!
      read_facts = read(booked[:request])
      expect(read_facts).to have_attributes(performer_cnes: booked[:unit].cnes, performer_cbo: "225250", sigtap: "0401010074",
                                            scheduled_at: booked[:appointment].scheduled_at,
                                            authorized_at: booked[:request].current_authorization.created_at)
      bundle = described_class.build(facts: read_facts, sync: sync_row, status: target("booked"), now: now)
      expect(res(bundle, "ServiceRequest").dig("performer", 0, "identifier", "value")).to eq(booked[:unit].cnes)
      expect(code_of(res(bundle, "Appointment").dig("specialty", 0))).to eq("225250")
    end

    it "booked sem turno: performer_cbo da oferta → default_performer_cbo do prestador" do
      booked = own_booked!(shift: false)
      expect(booked[:request].status).to eq("scheduled")
      expect(read(booked[:request]).performer_cbo).to be_nil
      booked[:provider].update!(default_performer_cbo: "225270")
      expect(read(booked[:request]).performer_cbo).to eq("225270")
      booked[:offer].update!(performer_cbo: "225265")
      expect(read(booked[:request]).performer_cbo).to eq("225265")
    end

    it "booked externo pelo estado: CNES do care_provider_id; scheduled_at no start, requested_at no authoredOn" do
      settings.update!(send_external: true)
      provider = external_provider!
      request = schedule_external!(regulation_request!(status: "external", unit: requester_unit), provider: provider,
                                   at: (now + 5.days).change(hour: 14))
      read_facts = read(request, credential: rnds_regulation_credential!)
      expect(read_facts).to have_attributes(own_network: false, performer_cnes: provider.cnes)
      bundle = described_class.build(facts: read_facts, sync: sync_row, status: Regulation::RndsStatus.for(request, settings: settings),
                                     now: now)
      expect(res(bundle, "Appointment")).to include("status" => "booked", "start" => (now + 5.days).change(hour: 14).iso8601)
      expect(res(bundle, "ServiceRequest")).to include("authoredOn" => request.requested_at.iso8601)
      expect(res(bundle, "ServiceRequest").dig("performer", 0, "identifier", "value")).to eq(provider.cnes)
      expect(Regulation::RiraSkeleton.problems(bundle)).to eq([])
    end

    it "absence na rede própria: o Appointment.start é o scheduled_at do no_show da cadeia (Q18)" do
      booked = own_booked!(shift: false)
      missed = no_show!(booked[:appointment])
      CareRegulation::AppointmentSync.call(appointment_request_id: booked[:appointment].request_id)
      request = booked[:request].reload
      expect(request).to have_attributes(status: "pending", misses: 1)
      read_facts = read(request, credential: rnds_regulation_credential!)
      expect(read_facts.absence_times).to eq([ missed.scheduled_at ])
      expect(read_facts.status_times["absence"]).to eq(request.events.select { |e| e.status == "missed" }.last.created_at)
      step = Regulation::RndsStatus.steps(request, since: nil, settings: settings).first
      bundle = described_class.build(facts: read_facts, sync: sync_row, status: step, now: Time.current)
      expect(res(bundle, "Appointment")).to include("status" => "noshow", "start" => missed.scheduled_at.iso8601)
      expect(Regulation::RiraSkeleton.problems(bundle)).to eq([])
    end
  end
end
