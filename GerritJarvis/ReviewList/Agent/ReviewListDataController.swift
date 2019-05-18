//
//  GerritAgent.swift
//  GerritJarvis
//
//  Created by Chuanren Shang on 2019/5/10.
//  Copyright © 2019 Chuanren Shang. All rights reserved.
//

import Cocoa

class ReviewListDataController: NSObject {

    static let ReviewListUpdatedNotification = Notification.Name("ReviewListUpdatedNotification")
    static let ReviewListNewEventsNotification = Notification.Name("ReviewListNewEventsNotification")
    static let ReviewListNewEventsKey = "ReviewListNewEventsKey"
    static let ReviewChangeNumberKey = "ReviewChangeNumberKey"
    private let ReviewNewEventStatusKey = "ReviewNewEventStatusKey"

    private(set) var cellViewModels = [ReviewListCellViewModel]()
    private(set) var changes = [Change]()
    @objc dynamic var isFetchingList: Bool = false

    private var gerritService: GerritService?
    private var timer: Timer?
    private var isFirstLoading: Bool = false
    private var newEventStates: [String : Bool] {
        get  {
            guard let status = UserDefaults.standard.object(forKey: ReviewNewEventStatusKey) as? [String : Bool] else {
                return [String : Bool]()
            }
            return status
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ReviewNewEventStatusKey)
        }
    }

    override init() {
        super.init()
        NSUserNotificationCenter.default.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccountUpdated(notification:)),
            name: ConfigManager.AccountUpdatedNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func changeAccount(user: String, password: String) {
        stopTimer()
        isFirstLoading = true
        gerritService = GerritService(user: user, password: password, baseUrl: ConfigManager.GerritBaseUrl)
        startTimer()
    }

    func fetchReviewList() {
        if isFetchingList {
            return
        }
        isFetchingList = true
        gerritService?.fetchReviewList { changes in
            self.isFetchingList = false
            guard let changes = changes else {
                return
            }
            let newChanges = self.reorderChanges(changes)
            self.checkMerged(newChanges)
            self.updateChanges(newChanges)
            self.updateAllNewEventsCount()
            self.sendReviewListUpdatedNotification()
            self.isFirstLoading = false
        }
    }

    func updateAllNewEventsCount() {
        var newEvents = 0
        for vm in cellViewModels {
            if vm.hasNewEvent {
                newEvents += 1
            }
        }
        updateNewEventStates()
        let userInfo = [ ReviewListDataController.ReviewListNewEventsKey: newEvents ]
        NotificationCenter.default.post(name: ReviewListDataController.ReviewListNewEventsNotification,
                                        object: nil,
                                        userInfo: userInfo)

    }

    func clearAllNewEvents() {
        for vm in cellViewModels {
            vm.resetEvent()
        }
        updateAllNewEventsCount()
    }

    @objc func handleAccountUpdated(notification: Notification) {
        guard let user = notification.userInfo?[ConfigManager.UserKey] as? String,
            let password = notification.userInfo?[ConfigManager.PasswordKey] as? String else {
            return
        }
        changeAccount(user: user, password: password)
    }

}

// MARK: - Refresh Timer
extension ReviewListDataController {

    private func startTimer() {
        if timer != nil {
            return
        }
        let interval: TimeInterval = ConfigManager.shared.refreshFrequency * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: { _ in
            self.fetchReviewList()
        })
        timer?.fire()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

}

// MARK: - Update Changes
extension ReviewListDataController {

    private func updateChanges(_ newChanges: [Change]) {
        var viewModels = [ReviewListCellViewModel]()
        for change in newChanges {
            var originChange: Change? = nil
            guard let newId = change.id else {
                continue
            }
            for old in changes {
                guard let oldId = old.id else {
                    continue
                }
                if newId == oldId {
                    originChange = old
                    break
                }
            }

            let viewModel = ReviewListCellViewModel(change: change)
            if viewModel.isOurNotReady && !ConfigManager.shared.showOurNotReadyReview {
                continue
            }

            var raiseMergeConflict = false
            if change.isOurs() {
                raiseMergeConflict = change.isRaiseMergeConflict(with: originChange)
                if raiseMergeConflict {
                    viewModel.hasNewEvent = true
                }
            }
            if let hasNewEvent = newEventStates[change.stateKey()] {
                if hasNewEvent {
                    viewModel.hasNewEvent = hasNewEvent
                } else {
                    viewModel.resetEvent()
                }
            }

            if originChange != nil {
                if raiseMergeConflict {
                    notifyMergeConflict(change)
                }
            } else {
                if !change.isOurs() {
                    notifyNewChange(change)
                }
            }

            if change.shouldListenReviewEvent() {
                let messages = change.newMessages(baseOn: originChange)
                let scores = GerritUtils.parseReviewScores(messages)
                let comments = GerritUtils.parseCommentCounts(messages)
                notifyReviewEvents(scores: scores, comments: comments, change: change)
            }

            viewModels.append(viewModel)
        }
        changes = newChanges
        cellViewModels = viewModels
    }

    private func reorderChanges(_ changes: [Change]) -> [Change] {
        var newChanges = [Change]()
        var insert = 0
        for change in changes {
            if change.isOurs() {
                newChanges.insert(change, at: insert)
                insert += 1
            } else {
                newChanges.append(change)
            }
        }
        return newChanges
    }

    private func updateNewEventStates() {
        var states = [String : Bool]()
        for vm in cellViewModels {
            states[vm.stateKey] = vm.hasNewEvent
        }
        newEventStates = states
    }

    private func sendReviewListUpdatedNotification() {
        NotificationCenter.default.post(name: ReviewListDataController.ReviewListUpdatedNotification,
                                        object: nil,
                                        userInfo: nil)
    }

}

// MARK: - Local Notification
extension ReviewListDataController : NSUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        guard let userInfo = notification.userInfo,
            let number = userInfo[ReviewListDataController.ReviewChangeNumberKey] as? Int else {
            return
        }

        var target: ReviewListCellViewModel? = nil
        for vm in cellViewModels {
            guard let changeNumber = vm.changeNumber else {
                continue
            }
            if changeNumber == number {
                target = vm
                break
            }
        }
        if let target = target {
            target.resetEvent()
            updateAllNewEventsCount()
            sendReviewListUpdatedNotification()
        }
        GerritUtils.openGerrit(number: number)
    }

    private func notifyReviewEvents(scores: [(Author, ReviewScore)],
                                    comments: [(Author, Int)],
                                    change: Change) {
        let reviewEvents = GerritUtils.combineReviewEvents(scores: scores, comments: comments)
        for (author, score, comments) in reviewEvents {
            if author.isMe() || (score == .Zero && comments == 0) {
                continue
            }

            var title = author.name ?? ""
            var imageName = "Comment"
            if score != .Zero {
                title += " Code-Review\(score.rawValue)"
                imageName = "Review\(score.rawValue)"
            }
            if comments != 0 {
                title += " (\(comments) "
                if comments == 1 {
                    title += "Comment)"
                } else {
                    title += "Comments)"
                }
            }
            postLocationNotification(title: title, image: NSImage.init(named: imageName), change: change)
        }
    }

    private func notifyMergeConflict(_ change: Change) {
        guard ConfigManager.shared.shouldNotifyMergeConflict else {
            return
        }
        postLocationNotification(title: "Merge Conflict",
                                 image: NSImage.init(named: "Conflict"),
                                 change: change)
    }

    private func notifyNewChange(_ change: Change) {
        guard ConfigManager.shared.shouldNotifyNewIncomingReview && change.hasNewEvent() else {
            return
        }
        let name = change.owner?.name ?? ""
        postLocationNotification(title: "New Review by \(name)",
            image: change.owner?.avatarImage(),
            change: change)
    }

    private func postLocationNotification(title: String, image: NSImage?, change: Change) {
        if isFirstLoading {
            // 第一次加载该用户的 Review List 时，不做任何通知
            return
        }
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = change.subject
        notification.contentImage = image
        if let number = change.number {
            notification.userInfo = [ ReviewListDataController.ReviewChangeNumberKey: number ]
        }
        debugPrint(notification)
        NSUserNotificationCenter.default.deliver(notification)
    }

}

// MARK: - Merged
extension ReviewListDataController {

    private func checkMerged(_ newChanges: [Change]) {
        var leaveChanges = [Change]()
        for change in changes {
            var found = false
            for new in newChanges {
                if new.id == change.id {
                    found = true
                    break
                }
            }
            if !found {
                leaveChanges.append(change)
            }
        }

        for change in leaveChanges {
            guard change.isOurs(),
                let changeId = change.changeId else {
                continue
            }
            gerritService?.fetchChangeDetail(changeId: changeId, completion: { change in
                guard let change = change, change.isMerged() else {
                    return
                }
                guard let name = change.owner?.name,
                    let mergedName = change.mergedBy(),
                    name != mergedName else {
                    return
                }
                self.postLocationNotification(title: "我的 Review Merged!",
                                              image: NSImage.init(named: "Merged"),
                                              change: change)
            })
        }
    }

}