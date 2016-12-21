class AssignmentSnapshot < ActiveRecord::Base

  belongs_to :assignment, inverse_of: :snapshots
  has_many :adapter_snapshots

  validates :assignment, presence: true
  validates :summary, presence: true, if: :fulfilled?
  validates :status, inclusion: { in: [nil, Term::IN_PROGRESS, Term::COMPLETED, Term::FAILED] }
  validates :xid, presence: true

  before_validation :set_up, on: :create
  before_validation :check_fulfillment
  after_create :create_adapter_snapshots
  after_save :report_snapshot, if: :report_to_coordinator

  scope :unfulfilled, -> { where fulfilled: false }

  def unfulfilled?
    !fulfilled?
  end

  def details
    JSON.parse(details_json) if details_json.present?
  end

  def details=(new_details)
    self.details_json = new_details.present? ? new_details.to_json : nil
    self.details
  end


  private

  attr_accessor :report_to_coordinator

  def adapter
    assignment.adapter
  end

  def set_up
    self.xid ||= SecureRandom.uuid
    return if fulfilled? || assignment.nil?
    response = adapter.get_status(self)

    if response.present? && response.errors.blank?
      parse_adapter_response response
    else
      errors.add(:base, "Invalid adapter response.")
      Notification.delay.snapshot_failure assignment, response.try(:errors)
    end
  end

  def parse_adapter_response(response)
    return unless response.fulfilled

    self.fulfilled = true
    self.status = response.status
    self.summary ||= response.summary
    self.value = response.value
    self.details = response.details
    self.description = response.description
    self.description_url = response.description_url
  end

  def check_fulfillment
    if undoing_fulfilled?
      errors.add(:fulfilled, "cannot be undone")
    elsif new_and_fulfilled? || fulfilled_after?
      self.report_to_coordinator = true
    end
  end

  def new_and_fulfilled?
    new_record? && fulfilled?
  end

  def fulfilled_after?
    persisted? && fulfilled? && changed_attributes[:fulfilled] == false
  end

  def undoing_fulfilled?
    persisted? && unfulfilled? && changed_attributes[:fulfilled]
  end

  def report_snapshot
    coordinator.snapshot id
    self.report_to_coordinator = false
  end

  def coordinator
    assignment.coordinator
  end

  def create_adapter_snapshots
    assignment.adapter_assignments.each do |adapter_assignment|
      adapter_snapshots.create(adapter_assignment: adapter_assignment)
    end
  end

end
