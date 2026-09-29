# spec/services/campaigns/criteria/care_criteria_spec.rb
require "rails_helper"

# Cada critério prova: entra, não entra e as duas bordas do período (inclusivas
# no fuso da cidade), quando há período.
RSpec.describe "Critérios de atendimento e agendamento" do
  before { create_default_protocol! }

  let(:from) { Time.zone.today - 30 }
  let(:to) { Time.zone.today - 10 }
  let(:first_instant) { from.in_time_zone.beginning_of_day }
  let(:last_instant) { to.in_time_zone.end_of_day }
  let(:inside) { first_instant + 2.days }
  let(:period) { { "from" => from.iso8601, "to" => to.iso8601 } }

  def ids(klass, params) = Citizen.where(id: klass.relation(params)).pluck(:id)

  it "todo kind do schema tem classe, e vice-versa" do
    expect(Campaigns::AudienceSchema::CRITERIA.keys).to match_array(Campaigns::Criteria::KINDS.keys)
    Campaigns::Criteria::KINDS.each_key { |kind| expect(Campaigns::Criteria.for(kind)).to respond_to(:relation) }
  end

  describe Campaigns::Criteria::AttendanceOutcome do
    let(:other_unit) { create_unit("UPA Norte", kind: "upa") }

    it "entra quem teve atendimento encerrado com desfecho na lista, no período e na unidade dada" do
      discharged = person!.tap { |c| CampaignHistory.attendance!(c, outcome: "discharged", at: first_instant, unit: unit!, by: staff!) }
      left = person!.tap { |c| CampaignHistory.attendance!(c, outcome: "left", at: last_instant, unit: other_unit, by: staff!) }
      person!.tap { |c| CampaignHistory.attendance!(c, outcome: "referred", at: inside, unit: unit!, by: staff!) }
      person!.tap { |c| CampaignHistory.attendance!(c, outcome: "discharged", at: first_instant - 1.second, unit: unit!, by: staff!) }
      person!.tap { |c| CampaignHistory.attendance!(c, outcome: "discharged", at: last_instant + 1.second, unit: unit!, by: staff!) }

      params = { "kind" => "attendance_outcome", "outcomes" => %w[discharged left] }.merge(period)
      expect(ids(described_class, params)).to contain_exactly(discharged.id, left.id)
      expect(ids(described_class, params.merge("health_unit_id" => other_unit.id))).to eq([ left.id ])
    end
  end

  describe Campaigns::Criteria::AppointmentNoShow do
    it "entra quem faltou a horário confirmado com scheduled_at no período, com as duas bordas" do
      on_first = person!.tap { |c| CampaignHistory.no_show!(c, at: first_instant, unit: unit!, by: staff!) }
      on_last = person!.tap { |c| CampaignHistory.no_show!(c, at: last_instant, unit: unit!, by: staff!) }
      person!.tap { |c| CampaignHistory.no_show!(c, at: first_instant - 1.second, unit: unit!, by: staff!) }
      person!.tap { |c| CampaignHistory.no_show!(c, at: last_instant + 1.second, unit: unit!, by: staff!) }
      person!.tap { |c| CampaignHistory.request!(c, unit: unit!, by: staff!, at: inside) }
      expect(ids(described_class, { "kind" => "appointment_no_show" }.merge(period))).to contain_exactly(on_first.id, on_last.id)
    end

    # Horário no período em qualquer status que não seja no_show: não entra.
    def appointment_with_status!(citizen, status, at:)
      request = CampaignHistory.request!(citizen, unit: unit!, by: staff!, at: at - 7.days)
      live = Appointment::LIVE.include?(status)
      Appointment.create!(request: request, citizen: citizen, health_unit: unit!, scheduled_by_user: staff!,
                          scheduled_at: at, status: status, confirmation_deadline_at: at - 1.day,
                          confirmed_at: status == "scheduled" ? nil : at - 1.day, ended_at: live ? nil : at.end_of_day,
                          cancel_reason: status == "cancelled_by_citizen" ? "Não consigo ir nesse dia" : nil)
    end

    it "não entra quem tem horário no período em outro status (scheduled, confirmed, checked_in, cancelado, expirado)" do
      missed = person!.tap { |c| CampaignHistory.no_show!(c, at: inside, unit: unit!, by: staff!) }
      (Appointment::STATUSES - [ "no_show" ]).each do |status|
        person!.tap { |c| appointment_with_status!(c, status, at: inside) }
      end
      expect(Appointment.where(scheduled_at: inside).distinct.pluck(:status)).to match_array(Appointment::STATUSES)
      expect(ids(described_class, { "kind" => "appointment_no_show" }.merge(period))).to eq([ missed.id ])
    end
  end

  describe Campaigns::Criteria::AppointmentRequestOpen do
    let(:upa) { create_unit("UPA Norte", kind: "upa") }

    it "entra quem tem pedido aberto agora, filtrando tipo e unidade de destino quando dados" do
      back = person!.tap { |c| CampaignHistory.request!(c, kind: "return", unit: unit!, by: staff!) }
      referred = person!.tap { |c| CampaignHistory.request!(c, kind: "referral", unit: unit!, target: upa, by: staff!) }
      person!.tap { |c| CampaignHistory.request!(c, kind: "return", unit: unit!, by: staff!, status: "scheduled") }

      expect(ids(described_class, { "kind" => "appointment_request_open" })).to contain_exactly(back.id, referred.id)
      expect(ids(described_class, { "kind" => "appointment_request_open", "kinds" => [ "referral" ] })).to eq([ referred.id ])
      expect(ids(described_class, { "kind" => "appointment_request_open", "target_unit_id" => unit!.id })).to eq([ back.id ])
    end
  end
end
