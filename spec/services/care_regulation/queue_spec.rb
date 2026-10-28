require "rails_helper"

# Módulo 26a, Task 7 (ADR 0044; contrato §4, §13 G2): a fila do regulador.
# Ordem: vencidos primeiro, depois cor efetiva, depois requested_at, depois id,
# numa leitura só; cursor com o dia e o componente "vencido".
RSpec.describe CareRegulation::Queue do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { regulation_city! }
  let(:today) { Time.zone.today }
  let(:unit) { create_unit("UBS Fila") }
  let(:doctor) { doctor!(unit) }

  # Pedido feito `days` dias atrás (o prazo da cor entra pela data do pedido).
  def request_aged!(days, color, **over)
    travel_to((today - days).in_time_zone.change(hour: 12)) do
      regulation_request!(unit: unit, doctor: doctor, suggested_color: color, **over)
    end
  end

  def page(limit: 50, before: nil, today: self.today, **filters)
    described_class.page(filters: filters.transform_keys(&:to_s), before: before, limit: limit, today: today)
  end

  describe ".page — ordem (G2)" do
    let!(:green_late) { request_aged!(100, "green") }
    let!(:blue_late) { request_aged!(200, "blue") }
    let!(:red_new) { request_aged!(1, "red") }
    let!(:yellow) { request_aged!(5, "yellow") }

    it "vencidos primeiro, depois cor, data e id: o azul vencido vem antes do vermelho no prazo" do
      expect([ green_late, blue_late, red_new, yellow ].map(&:overdue?)).to eq([ true, true, false, false ])
      expect(page[:rows].map(&:id)).to eq([ green_late, blue_late, red_new, yellow ].map(&:id))
      expect(page[:next_before]).to be_nil
    end

    it "limit: 2 pagina pela fronteira vencido/no prazo sem repetir" do
      first = page(limit: 2)
      expect(first[:rows].map(&:id)).to eq([ green_late.id, blue_late.id ])
      expect(first[:next_before]).to be_a(String)
      second = page(limit: 2, before: first[:next_before])
      expect(second[:rows].map(&:id)).to eq([ red_new.id, yellow.id ])
      expect(second[:next_before]).to be_nil
    end

    it "a cor confirmada vale no lugar da sugerida (cor efetiva)" do
      yellow.update_columns(color: "red")
      expect(page[:rows].map(&:id)).to eq([ green_late.id, blue_late.id, yellow.id, red_new.id ])
    end

    it "o cursor leva o dia: a página 2 pedida depois da virada usa o dia da página 1" do
      first = page(limit: 2, today: today)
      second = page(limit: 2, before: first[:next_before], today: today + 1)
      expect(second[:rows].map(&:id)).to eq([ red_new.id, yellow.id ])
    end

    it "na virada, pedido que passa a vencer à meia-noite não é pulado nem repetido" do
      # Prazo de 7 dias, pedido há 7 dias: due_on = hoje (no prazo hoje, vencido amanhã). Mesmo requested_at: desempata o id.
      edges = [ request_aged!(7, "red"), request_aged!(7, "red") ].sort_by(&:id)
      first = page(limit: 3)
      expect(first[:rows].map(&:id)).to eq([ green_late.id, blue_late.id, edges.first.id ])
      # Na página 2 já é o dia seguinte: o dia do cursor manda, senão o segundo edge (agora vencido) seria pulado.
      second = page(limit: 3, before: first[:next_before], today: today + 1)
      expect(second[:rows].map(&:id)).to eq([ edges.last.id, red_new.id, yellow.id ])
      expect(second[:rows].map(&:id) & first[:rows].map(&:id)).to be_empty
    end

    it "overdue: \"true\" traz só due_on < hoje; \"false\" os outros" do
      expect(page(overdue: "true")[:rows].map(&:id)).to eq([ green_late.id, blue_late.id ])
      expect(page(overdue: "false")[:rows].map(&:id)).to eq([ red_new.id, yellow.id ])
    end

    it "color filtra a cor efetiva; type e target_code filtram o alvo" do
      yellow.update_columns(color: "red")
      expect(page(color: "red")[:rows].map(&:id)).to eq([ yellow.id, red_new.id ])
      expect(page(type: "specialty", target_code: "225120")[:rows].size).to eq(4)
      expect(page(type: "procedure")[:rows]).to eq([])
      expect(page(target_code: "225250")[:rows]).to eq([])
    end

    it "status padrão é pending; outros da fila filtram; os pedidos de outra situação ficam de fora" do
      blue_late.update_columns(status: "returned")
      expect(page[:rows].map(&:id)).to eq([ green_late.id, red_new.id, yellow.id ])
      expect(page(status: "returned")[:rows].map(&:id)).to eq([ blue_late.id ])
    end

    it "rascunho nunca entra na fila" do
      request_aged!(0, "red", status: "draft")
      expect(page[:rows].size).to eq(4)
    end

    it "filtro inválido → InvalidFilter com o campo" do
      { "status" => "draft", "type" => "exam", "color" => "purple", "overdue" => "yes", "target_code" => "ab" }.each do |field, value|
        expect { page(**{ field.to_sym => value }) }.to raise_error(described_class::InvalidFilter) { |e| expect(e.field).to eq(field) }
      end
      expect { page(status: "missed") }.to raise_error(described_class::InvalidFilter) { |e| expect(e.field).to eq("status") }
      expect { described_class.page(filters: { "status" => [ "pending" ] }, before: nil, limit: 5) }
        .to raise_error(described_class::InvalidFilter) { |e| expect(e.field).to eq("status") }
    end

    it "before adulterado ou do formato antigo → Cursor::Invalid" do
      expect { page(before: "lixo") }.to raise_error(CareRegulation::Cursor::Invalid)
      old = Base64.urlsafe_encode64(JSON.generate([ 0, Time.current.utc.iso8601(6), green_late.id ]), padding: false)
      expect { page(before: old) }.to raise_error(CareRegulation::Cursor::Invalid)
    end
  end

  describe ".counts" do
    it "uma consulta agregada; external vencido conta em overdue; só as situações em espera" do
      pending_late = request_aged!(100, "green")
      request_aged!(1, "red")
      external_late = request_aged!(100, "green", status: "external")
      returned = request_aged!(2, "red")
      returned.update_columns(status: "returned")
      authorized = request_aged!(2, "red")
      authorized.update_columns(status: "authorized")
      done = request_aged!(200, "blue")
      done.update_columns(status: "completed")
      request_aged!(0, "red", status: "draft")

      counts = nil
      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries << p[:sql] if p[:sql].include?("regulation_requests") }
      begin
        counts = described_class.counts(today: today)
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end
      expect(counts).to eq(pending: 2, overdue: 2, returned: 1, authorized: 1, external: 1)
      expect(queries.size).to eq(1)
      expect([ pending_late, external_late ].map(&:overdue?)).to eq([ true, true ])
    end
  end
end

RSpec.describe CareRegulation::Cursor do
  let(:time) { Time.utc(2026, 10, 28, 12, 0, 0, 123_456) }
  let(:id) { SecureRandom.uuid }

  it "encode/decode de ida e volta: [Date, vencido, rank, Time, id]" do
    raw = described_class.encode([ "2026-10-28", 0, 2, time, id ])
    expect(raw).to match(/\A[A-Za-z0-9_-]+\z/)
    expect(described_class.decode(raw)).to eq([ Date.new(2026, 10, 28), 0, 2, time, id ])
    expect(described_class.decode(described_class.encode([ Date.new(2026, 10, 28), 1, 3, time, id ])).first).to eq(Date.new(2026, 10, 28))
  end

  it "tupla de 3 elementos (formato antigo) ou de outro tamanho levanta Invalid" do
    old = Base64.urlsafe_encode64(JSON.generate([ 2, time.iso8601(6), id ]), padding: false)
    expect { described_class.decode(old) }.to raise_error(described_class::Invalid)
    long = Base64.urlsafe_encode64(JSON.generate([ "2026-10-28", 0, 2, time.iso8601(6), id, 1 ]), padding: false)
    expect { described_class.decode(long) }.to raise_error(described_class::Invalid)
  end

  it "valores fora do formato, não-texto e lixo levantam Invalid" do
    bad = [ [ "2026-13-40", 0, 2, time.iso8601(6), id ], [ "2026-10-28", 2, 2, time.iso8601(6), id ],
            [ "2026-10-28", 0, 4, time.iso8601(6), id ], [ "2026-10-28", 0, 2, "ontem", id ],
            [ "2026-10-28", 0, 2, time.iso8601(6), "x" ], [ "2026-10-28", "0", 2, time.iso8601(6), id ] ]
    bad.each do |tuple|
      expect { described_class.decode(Base64.urlsafe_encode64(JSON.generate(tuple), padding: false)) }.to raise_error(described_class::Invalid)
    end
    [ "", "!!!", nil, 12, "a" * 600, Base64.urlsafe_encode64("{}", padding: false) ].each do |raw|
      expect { described_class.decode(raw) }.to raise_error(described_class::Invalid)
    end
  end
end
