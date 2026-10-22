module CareLines
  PracticeStatus = Data.define(:key, :label, :citizen_label, :source, :tracked, :status, :done_at, :due_on, :count, :expected, :met, :points)
end
