# Situação de uma boa prática. inspect/to_s/pretty_print sem datas nem contagens: due_on e done_at
# derivam de âncoras pessoais (DUM + janela). O JSON é montado pelos controllers (Json), não por as_json.
module CareLines
  PracticeStatus = Data.define(:key, :label, :citizen_label, :source, :tracked, :status, :done_at, :due_on, :count, :expected, :met, :points) do
    def inspect = "#<CareLines::PracticeStatus key=#{key.inspect} status=#{status}>"
    alias_method :to_s, :inspect
    def pretty_print(q) = q.text(inspect)
  end
end
