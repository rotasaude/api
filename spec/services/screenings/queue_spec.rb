require "rails_helper"

# ADR 0030 (spec §4): a fila do acolhimento são os atendimentos aguardando
# que exigem escuta pelo escopo e não têm escuta concluída, por chegada.
RSpec.describe Screenings::Queue do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:t0) { Time.zone.parse("2026-10-07 08:00") }

  def complete!(attendance, destination: "same_day")
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: destination,
                              destination_params: {}, by: nurse)
    started
  end

  it "walk_in: só demanda espontânea, sem escuta concluída, por chegada; em curso e abandonada continuam" do
    late = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0 + 20.minutes)
    early = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0)
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(3), checked_in_at: t0 - 5.minutes)
    done = walk_in_attendance!(unit, citizen: screening_citizen!(4), checked_in_at: t0 - 10.minutes)
    complete!(done)
    Screenings::Start.call(attendance: late, by: nurse)
    elsewhere = walk_in_attendance!(create_unit("UBS Outra"), citizen: screening_citizen!(5), checked_in_at: t0)

    expect(described_class.items(unit).map(&:id)).to eq([ early.id, late.id ])
    expect(described_class.items(unit).map(&:id)).not_to include(scheduled.id, done.id, elsewhere.id)
    unit.update!(screening_scope: "all")
    expect(described_class.items(unit.reload).map(&:id)).to eq([ scheduled.id, early.id, late.id ])
  end

  it "abandonada volta à fila do acolhimento; quem já foi chamado sai" do
    abandoned = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
    screening = Screenings::Start.call(attendance: abandoned, by: nurse).payload[:screening]
    Screenings::Abandon.call(screening: screening, by: nurse)
    called = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0 + 1.minute)
    called.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)

    expect(described_class.items(unit).map(&:id)).to eq([ abandoned.id ])
  end

  # A exigência pelo escopo tem uma só definição: o SQL de requiring e o
  # Scope.required? concordam em todas as combinações.
  it "requiring concorda com Scope.required? nos dois escopos e nas duas origens" do
    walk_in = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0)
    %w[walk_in all].each do |scope|
      unit.update!(screening_scope: scope)
      [ walk_in, scheduled ].each do |attendance|
        attendance = Attendance.find(attendance.id)
        expect(described_class.requiring(unit).exists?(attendance.id))
          .to eq(Screenings::Scope.required?(attendance)), "#{scope}/#{attendance.appointment_id ? 'horário' : 'espontânea'}"
      end
    end
  end

  # Marcador "aguardando acolhimento" (contrato §9): o mesmo grupo 3 da fila
  # do profissional — exige escuta e não tem escuta concluída.
  describe ".awaiting?" do
    it "verdadeiro sem escuta, em curso ou abandonada; falso com escuta concluída ou fora do escopo" do
      acolhimento!
      none = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
      in_progress = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0)
      Screenings::Start.call(attendance: in_progress, by: nurse)
      abandoned = walk_in_attendance!(unit, citizen: screening_citizen!(3), checked_in_at: t0)
      Screenings::Abandon.call(screening: Screenings::Start.call(attendance: abandoned, by: nurse).payload[:screening],
                               by: nurse)
      done = walk_in_attendance!(unit, citizen: screening_citizen!(4), checked_in_at: t0)
      complete!(done)
      scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(5), checked_in_at: t0)

      awaiting = ->(a) { described_class.awaiting?(Attendance.find(a.id)) }
      expect([ none, in_progress, abandoned ].map(&awaiting)).to all(be(true))
      expect([ done, scheduled ].map(&awaiting)).to all(be(false))
      expect(described_class.pending(unit).pluck(:id)).to match_array([ none.id, in_progress.id, abandoned.id ])

      unit.update!(screening_scope: "all")
      expect(awaiting.call(scheduled)).to be(true)
    end

    # Spec §11.4: concorda com o grupo 3 da fila do profissional, que só
    # existe com protocolo de acolhimento ativo.
    it "falso para todos sem protocolo de acolhimento ativo" do
      none = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
      in_progress = walk_in_attendance!(unit, citizen: screening_citizen!(2), checked_in_at: t0)
      Screenings::Start.call(attendance: in_progress, by: nurse)
      expect([ none, in_progress ].map { |a| described_class.awaiting?(Attendance.find(a.id)) }).to all(be(false))

      acolhimento!
      expect(described_class.awaiting?(Attendance.find(none.id))).to be(true)
      expect(described_class.awaiting?(Attendance.find(none.id), active: false)).to be(false)
    end

    it "falso para quem já foi chamado" do
      acolhimento!
      called = walk_in_attendance!(unit, citizen: screening_citizen!(1), checked_in_at: t0)
      called.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)
      expect(described_class.awaiting?(called.reload)).to be(false)
    end
  end
end
