require "rails_helper"
require Rails.root.join("db/city_migrate/20261116900003_add_vector_surveillance.rb").to_s

# Módulo 35a (ADR 0054; contrato §1; plano, Task 4): o banco da vigilância.
# Ovitrampa com número único entre as ativas e uma leitura aberta por vez; a
# leitura coletada uma vez e contada só em palheta boa (correção com nota
# nova, cifrada); a tarefa só fecha, uma vez, com uma tarefa de
# intensificação aberta por ovitrampa (A-8); o LIRAa só anda draft → drawn →
# closed, estratos e quarteirões fixos fora do rascunho, um quarteirão por
# levantamento (A-7); o bloqueio só anda proposed → active | dismissed e
# active → closed; o caso só muda de bloqueio, com número fixo; ciclos 1–3;
# o livro do app aceita os itens de ovitrampa (W-4). Nada se apaga nem se
# esvazia.
RSpec.describe "Esquema da vigilância do módulo 35a", type: :model do
  before { vector_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern = nil, error: ActiveRecord::StatementInvalid, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(error, pattern)
  end

  def not_unique(pattern, &block) = refused(pattern, error: ActiveRecord::RecordNotUnique, &block)

  # Escrita crua (update_all): a recusa não deixa valor sujo no objeto.
  def raw_update(record, **attrs) = record.class.where(id: record.id).update_all(attrs)

  # Avaliados antes de qualquer savepoint recusado (que desfaria as linhas).
  let!(:coordinator) { endemic_coordinator! }
  let!(:household) { registry_household! }
  let!(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }

  def block!(number = SecureRandom.hex(3)) = city_block!(neighborhood: neighborhood, number: number)

  # `validate: false` grava sem as validações do modelo (para provar o banco).
  def saved!(record, validate) = record.tap { |r| r.save!(validate: validate) }

  def ovitrap!(number: "OV-#{SecureRandom.hex(3)}", validate: true, **over)
    saved!(Ovitrap.new({ number: number, household: household, consent_at: Time.current, installed_on: Time.zone.today,
                         installed_by_user: coordinator, origin: "dashboard", city_block: block! }.merge(over)), validate)
  end

  def reading!(ovitrap, installed_on: Time.zone.today, validate: true, **over)
    saved!(OvitrapReading.new({ ovitrap: ovitrap, installed_on: installed_on, epi_week: 202_646 }.merge(over)), validate)
  end

  def count(by = vector_lab!, **over) = { egg_count: 40, counted_at: Time.current, counted_by_user_id: by.id }.merge(over)

  def task!(reading, validate: true, **over)
    saved!(VectorTask.new({ kind: "ovitrap_intensification", ovitrap_reading: reading, ovitrap_id: reading.ovitrap_id }.merge(over)), validate)
  end

  def survey!(validate: true, **over)
    saved!(LiraaSurvey.new({ name: "LIRAa #{SecureRandom.hex(2)}", starts_on: Time.zone.today, ends_on: Time.zone.today + 6 }.merge(over)), validate)
  end

  def stratum!(survey, validate: true, **over)
    saved!(LiraaStratum.new({ liraa_survey: survey, name: "Estrato #{SecureRandom.hex(2)}", mode: "standard" }.merge(over)), validate)
  end

  def stratum_block!(stratum, block, **over)
    LiraaStratumBlock.create!({ liraa_stratum: stratum, liraa_survey_id: stratum.liraa_survey_id, city_block: block }.merge(over))
  end

  def draw!(survey) = survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 1)

  def transmission_block!(validate: true, **over) = saved!(TransmissionBlock.new({ disease_group: "arbovirus" }.merge(over)), validate)

  def confirm!(block)
    block.update!(status: "active", confirmed_at: Time.current, confirmed_by_user: coordinator, center_block_id: block!.id)
  end

  def device
    @device ||= begin
      agent = endemic_agent!
      FieldDevice.create!(user: agent, professional: agent.professional, name: "Tablet das endemias",
                          token_digest: FieldDevice.digest("rsf_#{SecureRandom.urlsafe_base64(32)}"))
    end
  end

  it "a migração espelha os catálogos; irreversível" do
    vc = VectorControl::Catalog
    expect([ AddVectorSurveillance::CONDITIONS, AddVectorSurveillance::EGGS, AddVectorSurveillance::TASK_KINDS,
             AddVectorSurveillance::LIRAA_MODES, AddVectorSurveillance::BLOCK_STATUSES, AddVectorSurveillance::UBV_NUMBERS ])
      .to eq([ vc::CONDITIONS, vc::EGGS, vc::TASK_KINDS, vc::LIRAA_MODES, vc::BLOCK_STATUSES, vc::UBV_NUMBERS ])
    expect(AddVectorSurveillance::OVITRAP_NUMBER).to eq(vc::OVITRAP_NUMBER.source.sub('\A', "^").sub('\z', "$"))
    expect([ AddVectorSurveillance::OVITRAP_STATUSES, AddVectorSurveillance::ORIGINS, AddVectorSurveillance::TASK_STATES,
             AddVectorSurveillance::SURVEY_STATUSES, AddVectorSurveillance::DRAW_ITEM_STATUSES,
             AddVectorSurveillance::DISEASE_GROUPS, AddVectorSurveillance::CASE_ADDED_BY ])
      .to eq([ Ovitrap::STATUSES, Ovitrap::ORIGINS, VectorTask::STATES, LiraaSurvey::STATUSES, LiraaDrawItem::STATUSES,
               TransmissionBlock::DISEASE_GROUPS, TransmissionBlockCase::ADDED_BY ])
    expect(AddVectorSurveillance::ITEM_TYPES).to eq(FieldSync::Catalog::ITEM_TYPES)
    expect(FieldSync::Catalog::ITEM_TYPES.last(2)).to eq(%w[ovitrap_installation ovitrap_collection])
    expect { AddVectorSurveillance.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  describe "ovitrampa" do
    it "número repetido entre ativas → RecordNotUnique; repetido de uma removida passa" do
      first = ovitrap!(number: "OV-12")
      not_unique(/idx_ovitraps_number/) { ovitrap!(number: "ov-12") }
      first.update!(status: "removed", removed_on: Time.zone.today)
      expect { ovitrap!(number: "OV-12") }.not_to raise_error
      refused(/ck_ovitraps_number/) { ovitrap!(number: "OV 13", validate: false) }
      refused(error: ActiveRecord::ValueTooLong) { ovitrap!(number: "A" * 13, validate: false) }
    end

    it "removida ⇔ data de retirada; origem do app ⇔ aparelho; client_uuid único; consentimento obrigatório" do
      device # fora do savepoint recusado (que desfaria o aparelho memorizado)
      refused(/ck_ovitraps_removed/) { ovitrap!(status: "lost") }
      refused(/ck_ovitraps_removed/) { ovitrap!(removed_on: Time.zone.today) }
      refused(/ck_ovitraps_status/) { ovitrap!(status: "broken", removed_on: Time.zone.today, validate: false) }
      refused(/ck_ovitraps_origin/) { ovitrap!(origin: "whatsapp", validate: false) }
      refused(/ck_ovitraps_origin/) { ovitrap!(origin: "field_app") }
      refused(/ck_ovitraps_origin/) { ovitrap!(field_device: device) }
      uuid = SecureRandom.uuid
      ovitrap!(origin: "field_app", field_device: device, client_uuid: uuid)
      not_unique(/idx_ovitraps_client_uuid/) { ovitrap!(origin: "field_app", field_device: device, client_uuid: uuid) }
      refused(error: ActiveRecord::NotNullViolation) { ovitrap!(consent_at: nil) }
      refused(error: ActiveRecord::NotNullViolation) { ovitrap!(city_block: nil, validate: false) }
    end

    it "retirada ou perdida nunca volta a ativa; a data de retirada nunca some" do
      ovitrap = ovitrap!
      ovitrap.update!(status: "lost", removed_on: Time.zone.today)
      refused(/ovitraps: a removed or lost ovitrap never becomes active again/) { raw_update(ovitrap, status: "active", removed_on: nil) }
      refused(/ovitraps: removed_on is never cleared/) { raw_update(ovitrap, removed_on: nil) }
      expect { ovitrap.update!(status: "removed") }.not_to raise_error
    end
  end

  describe "leitura" do
    let!(:ovitrap) { ovitrap! }

    it "duas leituras abertas na mesma ovitrampa → RecordNotUnique" do
      first = reading!(ovitrap)
      not_unique(/idx_ovitrap_readings_open/) { reading!(ovitrap) }
      first.update!(collected_on: Time.zone.today + 7, condition: "ok")
      expect { reading!(ovitrap, installed_on: Time.zone.today + 7, epi_week: 202_647) }.not_to raise_error
    end

    it "semana epidemiológica YYYYWW (A-9); coleta com condição; contagem em palheta avariada → CHECK" do
      refused(/ck_ovitrap_readings_epi_week/) { reading!(ovitrap, epi_week: 202_654) }
      refused(/ck_ovitrap_readings_epi_week/) { reading!(ovitrap, epi_week: 202_600) }
      refused(/ck_ovitrap_readings_collection/) { reading!(ovitrap, collected_on: Time.zone.today) }
      refused(/ck_ovitrap_readings_condition/) { reading!(ovitrap, collected_on: Time.zone.today, condition: "wet", validate: false) }
      refused(/ck_ovitrap_readings_count/) { reading!(ovitrap, collected_on: Time.zone.today, condition: "damaged", **count) }
      refused(/ck_ovitrap_readings_count/) { reading!(ovitrap, **count) }
      refused(/ck_ovitrap_readings_eggs/) { reading!(ovitrap, collected_on: Time.zone.today, condition: "ok", **count(egg_count: 10_000)) }
      refused(/ck_ovitrap_readings_counted/) { reading!(ovitrap, collected_on: Time.zone.today, condition: "ok", **count(counted_at: nil)) }
      expect { reading!(ovitrap, collected_on: Time.zone.today, condition: "ok", **count(egg_count: 0)) }.not_to raise_error
    end

    it "coleta uma vez; contagem de NULL a valor sem nota, corrigida só com nota nova; re-cifra passa" do
      reading = reading!(ovitrap)
      reading.update!(collected_on: Time.zone.today + 7, condition: "ok")
      refused(/ovitrap_readings: a reading is collected once/) { raw_update(reading, condition: "dry") }
      refused(/ovitrap_readings: only the collection and the count change/) { raw_update(reading, epi_week: 202_647) }
      refused(/ovitrap_readings: the first count has no note/) { reading.reload.update!(**count, count_note: "Contagem refeita na lupa") }
      reading.reload.update!(**count)
      refused(/ovitrap_readings: correcting a count needs a new note/) { raw_update(reading, egg_count: 41) }
      refused(/ovitrap_readings: the count is never cleared/) { raw_update(reading, egg_count: nil, counted_at: nil, counted_by_user_id: nil) }
      reading.reload.update!(egg_count: 38, count_note: "Recontagem com lupa estereoscópica")
      expect(ApplicationRecord.connection.select_value("SELECT count_note FROM ovitrap_readings WHERE id = '#{reading.id}'"))
        .not_to include("lupa")
      refused(/correcting a count needs a new note/) { raw_update(reading, egg_count: 39) }
      expect { CityEncryption.allowing_reencryption { reading.encrypt } }.not_to raise_error
      expect(reading.reload.count_note).to eq("Recontagem com lupa estereoscópica")
      expect(reading.inspect).not_to include("lupa")
      expect(reading.as_json.to_s).not_to include("lupa")
    end
  end

  describe "tarefa" do
    let!(:reading) { reading!(ovitrap!, collected_on: Time.zone.today, condition: "ok") }

    it "duas tarefas de intensificação abertas para a mesma ovitrampa → RecordNotUnique" do
      first = task!(reading)
      not_unique(/idx_vector_tasks_open_ovitrap/) { task!(reading) }
      first.update!(state: "done", closed_by_user: coordinator)
      expect { task!(reading) }.not_to raise_error
    end

    it "uma referência só; ovitrampa ⇔ leitura ⇔ intensificação; fechada ⇔ quem fechou" do
      refused(/ck_vector_tasks_reference/) { task!(reading, transmission_block_id: transmission_block!.id) }
      refused(/ck_vector_tasks_reference/) { VectorTask.create!(kind: "block_case_without_place") }
      refused(/ck_vector_tasks_ovitrap/) { task!(reading, ovitrap_id: nil) }
      refused(/ck_vector_tasks_ovitrap/) do
        VectorTask.create!(kind: "block_case_without_place", transmission_block_id: transmission_block!.id, ovitrap_id: reading.ovitrap_id)
      end
      refused(/ck_vector_tasks_kind/) { task!(reading, kind: "visit", validate: false) }
      refused(/ck_vector_tasks_closed/) { task!(reading, state: "done") }
      refused(/ck_vector_tasks_closed/) { task!(reading, closed_by_user: coordinator) }
      expect { VectorTask.create!(kind: "block_case_without_place", transmission_block_id: transmission_block!.id) }.not_to raise_error
    end

    it "o tipo manda na referência (§6, §8): leitura, notificação, bloqueio" do
      block_id = transmission_block!.id
      refused(/ck_vector_tasks_reference/) { VectorTask.create!(kind: "case_resident_elsewhere", transmission_block_id: block_id) }
      refused(/ck_vector_tasks_reference/) do
        VectorTask.create!(kind: "block_case_without_place", ovitrap_reading: reading, ovitrap_id: reading.ovitrap_id)
      end
      refused(/ck_vector_tasks_reference/) { task!(reading, kind: "block_case_without_place") }
      expect { VectorTask.create!(kind: "block_case_without_place", transmission_block_id: block_id) }.not_to raise_error
    end

    it "a ovitrampa da tarefa é a da leitura (A-8, FK composta)" do
      other = ovitrap!
      refused(/fk_vector_tasks_reading_ovitrap/, error: ActiveRecord::InvalidForeignKey) { task!(reading, ovitrap_id: other.id) }
      expect(task!(reading).ovitrap_id).to eq(reading.ovitrap_id)
    end

    it "só open → done | dismissed, uma vez; re-cifra passa" do
      task = task!(reading)
      refused(/vector_tasks: an open task only goes to done or dismissed/) { raw_update(task, suggested_block_ids: [ block!.id ]) }
      task.update!(state: "dismissed", closed_by_user: coordinator, closed_note: "Ovitrampa já intensificada no ciclo")
      refused(/vector_tasks: a task is closed once/) { raw_update(task, state: "done") }
      refused(/vector_tasks: a task is closed once/) { raw_update(task, state: "open", closed_by_user_id: nil, closed_note: nil) }
      expect { CityEncryption.allowing_reencryption { task.encrypt } }.not_to raise_error
      expect(task.reload.closed_note).to eq("Ovitrampa já intensificada no ciclo")
      expect([ task.inspect, task.to_s, task.as_json.to_s ].join).not_to include("intensificada")
    end
  end

  describe "LIRAa" do
    it "levantamento só draft → drawn → closed; domínios e datas" do
      refused(/ck_liraa_surveys_status/) { survey!(status: "open", drawn_at: Time.current, parameters_version: 1, validate: false) }
      refused(/ck_liraa_surveys_dates/) { survey!(ends_on: Time.zone.today - 1) }
      refused(/ck_liraa_surveys_drawn/) { survey!(status: "drawn") }
      survey = survey!
      refused(/liraa_surveys: status goes draft -> drawn -> closed/) { raw_update(survey, status: "closed", closed_at: Time.current) }
      draw!(survey)
      refused(/liraa_surveys: a drawn survey only closes/) { raw_update(survey, name: "Outro nome") }
      refused(/liraa_surveys: status goes draft -> drawn -> closed/) { raw_update(survey, status: "draft", drawn_at: nil) }
      survey.update!(status: "closed", closed_at: Time.current)
      refused(/liraa_surveys: a closed survey never changes/) { raw_update(survey, name: "Outro nome") }
    end

    it "A-4: sorteio sem parâmetros gravados guarda a versão 0; negativa não" do
      expect { survey!.update!(status: "drawn", drawn_at: Time.current, parameters_version: 0) }.not_to raise_error
      refused(/ck_liraa_surveys_parameters_version/) { survey!.update!(status: "drawn", drawn_at: Time.current, parameters_version: -1) }
    end

    it "Review Focus 1: um substituto só por item (idx_liraa_draw_items_substitute)" do
      stratum = stratum!(survey!)
      block = block!
      item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1)
      LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: registry_household!, position: 2, substitute_of: item)
      not_unique(/idx_liraa_draw_items_substitute/) do
        LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: registry_household!, position: 3, substitute_of: item)
      end
    end

    it "o mesmo quarteirão em dois estratos do mesmo levantamento → RecordNotUnique; em levantamentos diferentes passa" do
      survey = survey!
      block = block!
      stratum_block!(stratum!(survey), block)
      not_unique(/idx_liraa_stratum_blocks_block/) { stratum_block!(stratum!(survey), block) }
      expect { stratum_block!(stratum!(survey!), block) }.not_to raise_error
    end

    it "o levantamento do quarteirão do estrato é o do estrato (A-7); início 1–5, só no sorteado" do
      stratum = stratum!(survey!)
      refused(/liraa_stratum_blocks: liraa_survey_id differs from the stratum/) do
        stratum_block!(stratum, block!, liraa_survey_id: survey!.id)
      end
      refused(/ck_liraa_stratum_blocks_household_start/) { stratum_block!(stratum, block!, drawn: true, household_start: 6) }
      refused(/ck_liraa_stratum_blocks_drawn/) { stratum_block!(stratum, block!, drawn: true) }
      refused(/ck_liraa_stratum_blocks_drawn/) { stratum_block!(stratum, block!, household_start: 1) }
      expect { stratum_block!(stratum, block!, drawn: true, household_start: 1) }.not_to raise_error
      refused(/ck_liraa_stratum_blocks_base/) { stratum_block!(stratum, block!, base_household_ids: [ household.id ]) } # Q25
      expect { stratum_block!(stratum, block!, drawn: true, household_start: 1, base_household_ids: [ household.id ]) }.not_to raise_error
      refused(/ck_liraa_strata_mode/) { stratum!(stratum.liraa_survey, mode: "quarter", validate: false) }
    end

    it "estrato muda depois do sorteio → trigger; quarteirões do estrato também" do
      survey = survey!
      stratum = stratum!(survey)
      row = stratum_block!(stratum, block!)
      stratum.update!(households_count: 2400, sample_target: 360, block_interval: 3, random_start: 2)
      row.update!(drawn: true, household_start: 1)
      draw!(survey)
      refused(/liraa_strata: strata change only while the survey is a draft/) { raw_update(stratum, sample_target: 400) }
      refused(/liraa_strata: strata change only while the survey is a draft/) { stratum!(survey) }
      refused(/liraa_stratum_blocks: blocks change only while the survey is a draft/) { raw_update(row, drawn: false, household_start: nil) }
      refused(/liraa_stratum_blocks: blocks change only while the survey is a draft/) { stratum_block!(stratum, block!) }
    end

    it "no rascunho, quarteirão do estrato e estrato se apagam (nessa ordem); depois do sorteio, não" do
      survey = survey!
      stratum = stratum!(survey)
      row = stratum_block!(stratum, block!)
      refused(error: ActiveRecord::InvalidForeignKey) { stratum.delete }
      expect { row.delete }.not_to raise_error
      expect { stratum.delete }.not_to raise_error
      expect([ LiraaStratum.exists?(stratum.id), LiraaStratumBlock.exists?(row.id) ]).to eq([ false, false ])

      kept = stratum!(survey)
      kept_row = stratum_block!(kept, block!)
      draw!(survey)
      refused(/liraa_stratum_blocks: DELETE refused outside a draft survey/) { kept_row.delete }
      refused(/liraa_strata: DELETE refused outside a draft survey/) { LiraaStratum.where(id: kept.id).delete_all }
    end

    it "item do sorteio só muda status e substituto; volta a pending; nada com o levantamento fechado" do
      survey = survey!
      stratum = stratum!(survey)
      block = block!
      item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1)
      draw!(survey)
      refused(/liraa_draw_items: only status and substitute_of_id change/) { raw_update(item, position: 2) }
      item.update!(status: "inspected")
      refused(/liraa_draw_items: status goes pending -> inspected \| substituted and back to pending/) { raw_update(item, status: "substituted") }
      item.update!(status: "pending")
      item.update!(status: "substituted")
      survey.update!(status: "closed", closed_at: Time.current)
      refused(/liraa_draw_items: a closed survey never changes/) { raw_update(item, status: "pending") }
    end

    it "item do sorteio: domínio de status e um por domicílio no estrato" do
      survey = survey!
      stratum = stratum!(survey)
      block = block!
      item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1)
      not_unique(/idx_liraa_draw_items_household/) do
        LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 2)
      end
      refused(/ck_liraa_draw_items_status/) do
        LiraaDrawItem.new(liraa_stratum: stratum, city_block: block, household: registry_household!, position: 3, status: "skipped")
                     .save!(validate: false)
      end
      item.update!(status: "substituted")
      expect(item.reload).to have_attributes(status: "substituted")
    end
  end

  describe "bloqueio de transmissão" do
    it "bloqueio closed → active → trigger; dismissed sem motivo → CHECK" do
      refused(/ck_transmission_blocks_dismissed/) { transmission_block!(status: "dismissed") }
      refused(/ck_transmission_blocks_confirmed/) { transmission_block!(status: "active") }
      refused(/ck_transmission_blocks_disease_group/) { transmission_block!(disease_group: "dengue", validate: false) }
      block = transmission_block!
      confirm!(block)
      refused(/transmission_blocks: an active block only closes/) { raw_update(block, center_block_id: block!.id) }
      block.update!(status: "closed", closed_at: Time.current)
      refused(/transmission_blocks: status goes proposed -> active \| dismissed and active -> closed/) do
        raw_update(block, status: "active", closed_at: nil)
      end
      refused(/transmission_blocks: a closed or dismissed block never changes/) { raw_update(block, closed_at: Time.current) }
    end

    it "proposto → dismissed com motivo cifrado; nunca volta; re-cifra passa" do
      block = transmission_block!
      block.update!(center_block_id: block!.id)
      block.update!(status: "dismissed", dismissed_reason: "Casos descartados pela investigação")
      refused(/status goes proposed -> active/) { raw_update(block, status: "proposed", dismissed_reason: nil) }
      expect { CityEncryption.allowing_reencryption { block.encrypt } }.not_to raise_error
      expect(block.reload.dismissed_reason).to eq("Casos descartados pela investigação")
      expect([ block.inspect, block.to_s, block.as_json.to_s ].join).not_to include("descartados")
    end

    it "área única pelo par; ciclo 4 → CHECK; ciclo único por número" do
      block = transmission_block!
      city_block = block!
      TransmissionBlockArea.create!(transmission_block: block, city_block: city_block)
      not_unique(/idx_transmission_block_areas_pair/) { TransmissionBlockArea.create!(transmission_block: block, city_block: city_block) }
      cycle = ->(number) { TransmissionBlockCycle.create!(transmission_block: block, number: number, starts_on: Time.zone.today, ends_on: Time.zone.today + 2) }
      refused(/ck_transmission_block_cycles_number/) { cycle.call(4) }
      refused(/ck_transmission_block_cycles_number/) { cycle.call(0) }
      cycle.call(1)
      not_unique(/idx_transmission_block_cycles_number/) { cycle.call(1) }
      refused(/ck_transmission_block_cycles_dates/) do
        TransmissionBlockCycle.create!(transmission_block: block, number: 2, starts_on: Time.zone.today, ends_on: Time.zone.today - 1)
      end
    end

    describe "casos" do
      before { surveillance_city! }

      let!(:notification) { notification!(patient: surveillance_patient!(1)) }

      def case!(block, number:, notification: self.notification, validate: true, **over)
        saved!(TransmissionBlockCase.new({ transmission_block: block, disease_notification: notification, case_on: notification.suspected_on,
                                           added_by: "job", number: number }.merge(over)), validate)
      end

      it "caso em dois bloqueios → RecordNotUnique; number do caso não muda (trigger); só muda de bloqueio (added_by job → user só no mover)" do
        first = transmission_block!
        other = transmission_block!
        row = case!(first, number: 1)
        not_unique(/idx_transmission_block_cases_notification/) { case!(other, number: 2) }
        refused(/transmission_block_cases: a case only moves to another block/) { raw_update(row, number: 7) }
        refused(/transmission_block_cases: a case only moves to another block/) { raw_update(row, case_on: Date.yesterday) }
        refused(/transmission_block_cases: added_by only goes job -> user in a move/) { raw_update(row, added_by: "user") }
        row.update!(transmission_block: other)
        expect(row.reload.transmission_block_id).to eq(other.id)
        row.update!(transmission_block: first, added_by: "user") # Q26(2): quem moveu, no mesmo UPDATE do mover
        expect(row.reload).to have_attributes(transmission_block_id: first.id, added_by: "user", number: 1)
        refused(/transmission_block_cases: added_by only goes job -> user in a move/) { raw_update(row, transmission_block_id: other.id, added_by: "job") }
        second = notification!(patient: surveillance_patient!(2))
        not_unique(/idx_transmission_block_cases_number/) { case!(other, number: 1, notification: second) }
        refused(/ck_transmission_block_cases_added_by/) { case!(other, number: 2, notification: second, added_by: "app", validate: false) }
        refused(/ck_transmission_block_cases_number/) { case!(other, number: 0, notification: second) }
      end

      it "a tarefa do caso de fora cita a notificação" do
        expect { VectorTask.create!(kind: "case_resident_elsewhere", disease_notification: notification) }.not_to raise_error
      end
    end
  end

  describe "livro do app (W-4)" do
    def receipt(item_type)
      FieldSyncReceipt.new(client_uuid: SecureRandom.uuid, field_device: device, user: device.user, item_type: item_type,
                           result_type: "OvitrapReading", result_id: SecureRandom.uuid)
    end

    it "receipt ovitrap_collection aceito pelo CHECK" do
      expect { receipt("ovitrap_collection").save!(validate: false) }.not_to raise_error
      expect { receipt("ovitrap_installation").save!(validate: false) }.not_to raise_error
      refused(/ck_field_sync_receipts_item_type/) { receipt("ovitrap_count").save!(validate: false) }
    end
  end

  it "a inspeção cita o item do sorteio e o bloqueio pela FK" do
    inspection = ->(**over) do
      VectorInspection.create!({ home_visit: home_visit!(household: household), household: household, activity: "liraa", work_type: "routine",
                                 situation: "worked", educational_action: true }.merge(over))
    end
    refused(error: ActiveRecord::InvalidForeignKey) { inspection.call(liraa_draw_item_id: SecureRandom.uuid) }
    refused(error: ActiveRecord::InvalidForeignKey) { inspection.call(activity: "transmission_block", transmission_block_id: SecureRandom.uuid) }
    expect { inspection.call(activity: "transmission_block", transmission_block_id: transmission_block!.id) }.not_to raise_error
  end

  it "nenhuma das onze aceita DELETE nem TRUNCATE" do
    ovitrap = ovitrap!
    reading = reading!(ovitrap)
    survey = survey!
    stratum = stratum!(survey)
    block = transmission_block!
    city_block = block!
    rows = [ ovitrap, reading, task!(reading), survey, stratum, stratum_block!(stratum, city_block),
             LiraaDrawItem.create!(liraa_stratum: stratum, city_block: city_block, household: household, position: 1), block,
             TransmissionBlockArea.create!(transmission_block: block, city_block: city_block),
             TransmissionBlockCycle.create!(transmission_block: block, number: 1, starts_on: Time.zone.today, ends_on: Time.zone.today) ]
    expect(rows.map { |row| row.class.table_name } + %w[transmission_block_cases]).to match_array(AddVectorSurveillance::TABLES)
    draw!(survey) # estrato e quarteirão do estrato só se apagam no rascunho
    rows.each { |row| refused(/#{row.class.table_name}/) { row.delete } }
    AddVectorSurveillance::TABLES.each do |table|
      refused(/#{table} is append-only/) { Ovitrap.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end
end
