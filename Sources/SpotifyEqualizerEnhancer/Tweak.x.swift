import Foundation
import Orion
import SpotifyEqualizerEnhancerC
import UIKit
import os

@objc protocol SPTEqualizerCurve {
  var values: [Double: Double] { get set }

  func initWithValues(_ values: [Double: Double]) -> AnyObject
  func valueForFrequency(_ frequency: Double) -> Double
  func setValue(_ value: Double, forFrequency frequency: Double)
}

@objc protocol SPTEqualizerModelDelegate {
  func equalizerModelDidChangeValue(_ model: SPTEqualizerModel)
  func equalizerModelDidUpdatePreset(_ model: SPTEqualizerModel)
}

@objc protocol SPTLocalSettings {
  func objectForKey(_ key: String) -> AnyObject?
  func setObject(_ object: AnyObject?, forKey key: String)
  func removeObjectForKey(_ key: String)
  func allKeys() -> [String]
}

@objc protocol SPTAudioDriverController {}

@objc protocol SPTConnectAggregatorManager {}

@objc protocol SPTRemoteConfigurationProperties {}

@objc protocol SPTPreferences {}

@objc protocol SPTEqualizerModel {
  var localSettings: SPTLocalSettings { get set }
  var delegate: SPTEqualizerModelDelegate? { get set }
  var presetCurves: [AnyObject] { get set }
  var bands: [Double] { get set }
  var values: [Double] { get set }
  var presets: [String] { get set }
  var preset: String? { get set }
  var on: Bool { get set }

  func applyEqualizer()
  func columnNameAtIndex(_ index: Int) -> String
  func defaultBands() -> [Double]
  func defaultValues() -> [Double]
}

@objc protocol SPTEncoreLabel {
  var numberOfLines: Int { get set }
  var adjustsFontSizeToFitWidth: Bool { get set }
  var textAlignment: NSTextAlignment { get set }
}

@objc protocol SPTEqualizerColumnView {
  var dataSource: Any? { get set }
  var labels: [UIView] { get set }
  var values: [Double] { get set }

  func reloadData()
}

@objc protocol SPTEqualizerView {
  var columnView: SPTEqualizerColumnView { get set }
  var tableView: UITableView { get set }
}

@objc protocol SPTEqualizerViewController {
  var equalizerView: SPTEqualizerView { get set }
  var model: SPTEqualizerModel { get set }

  func equalizerColumnLabelTapped(_ sender: UITapGestureRecognizer?)
  func equalizerColumnLabelLongPressed(_ sender: UILongPressGestureRecognizer?)
  func savePreset(_ presetName: String)
  func deletePreset(_ presetName: String)
}

struct EqualizerValue: Codable {
  var frequency: Double
  var value: Double
}

struct EqualizerPreset: Codable {
  var name: String
  var values: [EqualizerValue]
}

struct EqualizerPresetsPropertyList: Codable {
  var presets: [EqualizerPreset]
}

class SpotifyEqualizerEnhancer: Tweak {
  static var presetsPath: String {
    let documentDirectory = NSSearchPathForDirectoriesInDomains(
      .documentDirectory, .userDomainMask, true
    ).first!
    return (documentDirectory as NSString).appendingPathComponent("equalizer-presets.plist")
  }

  static var presetsURL: URL {
    URL(fileURLWithPath: self.presetsPath)
  }

  static var presets: [EqualizerPreset] {
    get {
      let decoder = PropertyListDecoder()
      let presets = try! decoder.decode(
        EqualizerPresetsPropertyList.self, from: try Data(contentsOf: presetsURL)
      ).presets
      return presets.sorted(by: { $0.name < $1.name })
    }
    set(presets) {
      let encoder = PropertyListEncoder()
      let presets = try! encoder.encode(
        EqualizerPresetsPropertyList(presets: presets.sorted(by: { $0.name < $1.name })))
      try! presets.write(to: presetsURL)
    }
  }

  required init() {
    if !FileManager.default.fileExists(atPath: SpotifyEqualizerEnhancer.presetsPath),
      let bundlePresetsPath = Bundle.main.path(forResource: "equalizer-presets", ofType: "plist")
    {
      try! FileManager.default.copyItem(
        atPath: bundlePresetsPath, toPath: SpotifyEqualizerEnhancer.presetsPath)
    }
  }
}

class EqualizerModelHook: ClassHook<NSObject> {
  static let targetName = "SPTEqualizerModel"

  // orion:new
  class func defaultBands() -> [Double] {
    return [60, 150, 400, 1000, 2400, 15000]
  }

  func initWithLocalSettings(
    _ localSettings: SPTLocalSettings, audioDriverController: SPTAudioDriverController,
    connectManager: SPTConnectAggregatorManager,
    remoteConfigurationProperties: SPTRemoteConfigurationProperties, preferences: SPTPreferences
  ) -> Target {
    let target = orig.initWithLocalSettings(
      localSettings, audioDriverController: audioDriverController, connectManager: connectManager,
      remoteConfigurationProperties: remoteConfigurationProperties, preferences: preferences)
    let model = target.as(interface: SPTEqualizerModel.self)

    let presets = SpotifyEqualizerEnhancer.presets
    model.presetCurves = presets.map {
      Dynamic.SPTEqualizerCurve.alloc(interface: SPTEqualizerCurve.self).initWithValues(
        $0.values.reduce(into: [:]) { $0[$1.frequency] = $1.value })
    }
    model.presets = presets.map { $0.name }

    if let bands = model.localSettings.objectForKey("enhancedBands") as? [Double],
      let values = model.localSettings.objectForKey("enhancedValues") as? [Double],
      bands.count > 1,
      values.count == bands.count
    {
      model.bands = bands
      model.values = values
    } else {
      let modelClass = Dynamic.SPTEqualizerModel.as(interface: SPTEqualizerModel.self)
      model.bands = modelClass.defaultBands()
      model.values = modelClass.defaultValues()
    }
    let presetName = model.localSettings.objectForKey("enhancedPersistedPresetName") as? String
    Ivars<NSString?>(model)._preset = presetName as? NSString
    return target
  }

  func setPreset(_ presetName: String?) {
    let model = target.as(interface: SPTEqualizerModel.self)

    if model.preset != presetName {
      let modelClass = Dynamic.SPTEqualizerModel.as(interface: SPTEqualizerModel.self)
      var bands = modelClass.defaultBands()
      var values = modelClass.defaultValues()

      if presetName != nil {
        let presetIndex = model.presets.firstIndex(of: presetName!)!
        let presetCurve = Dynamic.convert(
          model.presetCurves[presetIndex], to: SPTEqualizerCurve.self)

        if presetCurve.values.count > 1 {
          bands = [Double](presetCurve.values.keys).sorted()
          values = bands.map { presetCurve.valueForFrequency($0) }
        }
      }

      model.bands = bands
      model.values = values
      Ivars<NSString?>(model)._preset = presetName as? NSString
      model.delegate?.equalizerModelDidUpdatePreset(model)
    }
  }

  func setBands(_ bands: [Double]) {
    orig.setBands(bands)
    target.as(interface: SPTEqualizerModel.self).localSettings.setObject(
      bands as NSArray, forKey: "enhancedBands")
  }

  func setValues(_ values: [Double]) {
    let model = target.as(interface: SPTEqualizerModel.self)
    if model.values != values {
      Ivars<NSArray>(model)._values = values as NSArray
      Ivars<NSString?>(model)._preset = nil
      model.localSettings.setObject(values as NSArray, forKey: "enhancedValues")
      model.applyEqualizer()
      model.delegate?.equalizerModelDidChangeValue(model)
      model.delegate?.equalizerModelDidUpdatePreset(model)
      model.on = !values.allSatisfy { $0 == 0 }
    }
  }

  func persistPreset(_ presetName: String?) {
    target.as(interface: SPTEqualizerModel.self).localSettings.setObject(
      presetName as? NSString, forKey: "enhancedPersistedPresetName")
  }

  func resetPersistedPreset() {
    let localSettings = target.as(interface: SPTEqualizerModel.self).localSettings
    if localSettings.objectForKey("enhancedPersistedPresetName") != nil {
      localSettings.removeObjectForKey("enhancedPersistedPresetName")
    }
  }
}

class EqualizerViewControllerHook: ClassHook<UIViewController> {
  static let targetName = "SPTEqualizerViewController"

  // orion:new
  func equalizerColumnLabelTapped(_ sender: UITapGestureRecognizer?) {
    let equalizerViewController = target.as(interface: SPTEqualizerViewController.self)
    let columnView: SPTEqualizerColumnView = Dynamic.convert(
      equalizerViewController.equalizerView.columnView, to: SPTEqualizerColumnView.self)
    let labelIndex = columnView.labels.firstIndex(of: sender!.view!)!
    let model = equalizerViewController.model

    let alertController = UIAlertController(
      title: nil,
      message: "Set value for \(model.columnNameAtIndex(labelIndex)) band", preferredStyle: .alert)
    alertController.addTextField(configurationHandler: { textField in
      textField.text = String(model.values[labelIndex])
      textField.placeholder = "0.0"
      textField.keyboardType = .decimalPad
    })
    alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alertController.addAction(
      UIAlertAction(title: "OK", style: .default) { _ in
        if let textFieldText = alertController.textFields?.first?.text,
          let value = Double(textFieldText)
        {
          model.values[labelIndex] = value
        }
      })
    target.present(alertController, animated: true)
  }

  // orion:new
  func equalizerColumnLabelLongPressed(_ sender: UILongPressGestureRecognizer?) {
    let equalizerViewController = target.as(interface: SPTEqualizerViewController.self)
    let columnView: SPTEqualizerColumnView = Dynamic.convert(
      equalizerViewController.equalizerView.columnView, to: SPTEqualizerColumnView.self)
    let labelIndex = columnView.labels.firstIndex(of: sender!.view!)!
    let model = equalizerViewController.model

    let alertController = UIAlertController(
      title: nil, message: "Delete \(model.columnNameAtIndex(labelIndex)) band?",
      preferredStyle: .alert)
    alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alertController.addAction(
      UIAlertAction(
        title: "OK", style: .destructive,
        handler: { _ in
          guard model.bands.count > 2 else {
            let alertController = UIAlertController(
              title: nil, message: "Cannot have less than 2 EQ bands", preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default))
            self.target.present(alertController, animated: true)
            return
          }
          model.bands.remove(at: labelIndex)
          model.values.remove(at: labelIndex)
        }))
    target.present(alertController, animated: true)
  }

  // orion:new
  func savePreset(_ presetName: String) {
    let equalizerViewController = target.as(interface: SPTEqualizerViewController.self)
    let model = equalizerViewController.model
    let valuesDict = Dictionary(uniqueKeysWithValues: zip(model.bands, model.values))
    let preset = EqualizerPreset(
      name: presetName, values: valuesDict.map { EqualizerValue(frequency: $0, value: $1) })

    SpotifyEqualizerEnhancer.presets.removeAll(where: { $0.name == presetName })
    SpotifyEqualizerEnhancer.presets.append(preset)

    let presetCurve = Dynamic.SPTEqualizerCurve.alloc(interface: SPTEqualizerCurve.self)
      .initWithValues(valuesDict)

    if let presetIndex = model.presets.firstIndex(of: presetName) {
      model.presetCurves[presetIndex] = presetCurve
    } else if let presetIndex = SpotifyEqualizerEnhancer.presets.firstIndex(where: {
      $0.name == presetName
    }) {
      model.presetCurves.insert(presetCurve, at: presetIndex)
      model.presets.append(presetName)
      model.presets.sort()
      equalizerViewController.equalizerView.tableView.insertRows(
        at: [IndexPath(row: presetIndex, section: 1)], with: .left)
    }

    model.preset = presetName
  }

  // orion:new
  func deletePreset(_ presetName: String) {
    let equalizerViewController = target.as(interface: SPTEqualizerViewController.self)
    let model = equalizerViewController.model
    let presetIndex = model.presets.firstIndex(of: presetName)!

    SpotifyEqualizerEnhancer.presets.removeAll(where: { $0.name == presetName })

    model.presets.remove(at: presetIndex)
    model.presetCurves.remove(at: presetIndex)

    equalizerViewController.equalizerView.tableView.deleteRows(
      at: [IndexPath(row: presetIndex, section: 1)], with: .left)
  }

  // orion:new
  func tableView(_: UITableView, canEditRowAtIndexPath indexPath: IndexPath) -> Bool {
    return indexPath.section == 1
  }

  // orion:new
  func tableView(
    _: UITableView, commitEditingStyle editingStyle: UITableViewCell.EditingStyle,
    forRowAtIndexPath indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }

    let equalizerViewController = self.target.as(interface: SPTEqualizerViewController.self)
    let presetName = equalizerViewController.model.presets[indexPath.row]

    let alertController = UIAlertController(
      title: nil, message: "Delete \(presetName)?", preferredStyle: .alert)
    alertController.addAction(UIAlertAction(title: "No", style: .cancel))
    alertController.addAction(
      UIAlertAction(
        title: "Yes", style: .destructive,
        handler: { _ in
          equalizerViewController.deletePreset(presetName)
        }))
    target.present(alertController, animated: true)
  }

  func equalizerColumnView(_ columnView: SPTEqualizerColumnView, nameOfValueIndex valueIndex: Int)
    -> String
  {
    let frequency = orig.equalizerColumnView(columnView, nameOfValueIndex: valueIndex)
    let value = String(format: "%.2f", columnView.values[valueIndex])
    return "\(frequency)\n\(value)"
  }

  func viewDidLoad() {
    orig.viewDidLoad()

    let model = target.as(interface: SPTEqualizerViewController.self).model

    let menu = UIMenu(children: [
      UIAction(
        title: "Add band", image: UIImage(systemName: "plus"),
        handler: { _ in
          let alertController = UIAlertController(
            title: "Add band", message: nil, preferredStyle: .alert)
          alertController.addTextField(configurationHandler: { textField in
            textField.placeholder = "Frequency (in Hz)"
            textField.keyboardType = .numberPad
          })
          alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
          alertController.addAction(
            UIAlertAction(
              title: "OK", style: .default,
              handler: { _ in
                if let textFieldText = alertController.textFields?.first?.text,
                  let band = Double(textFieldText),
                  !model.bands.contains(band)
                {
                  model.bands.append(band)
                  model.bands.sort()
                  model.values.insert(0, at: model.bands.firstIndex(of: band)!)
                }
              }))
          self.target.present(alertController, animated: true)
        }),
      UIAction(
        title: "Save preset", image: UIImage(systemName: "internaldrive"),
        handler: { _ in
          let alertController = UIAlertController(
            title: "Save preset", message: nil, preferredStyle: .alert)
          alertController.addTextField(configurationHandler: { textField in
            textField.placeholder = "Preset name"
          })
          alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
          alertController.addAction(
            UIAlertAction(
              title: "OK", style: .default,
              handler: { _ in
                if let presetName = alertController.textFields?.first?.text {
                  self.target.as(interface: SPTEqualizerViewController.self).savePreset(presetName)
                }
              }))
          self.target.present(alertController, animated: true)
        }),
    ])

    target.navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "line.horizontal.3")?.withRenderingMode(.alwaysOriginal)
        .withTintColor(UIColor.white), menu: menu)
  }
}

class EqualizerColumnViewHook: ClassHook<UIView> {
  static let targetName = "SPTEqualizerColumnView"

  func redrawValuesWithOldCount(_ oldCount: Int, animated _: Bool) {
    orig.redrawValuesWithOldCount(
      oldCount, animated: target.as(interface: SPTEqualizerColumnView.self).values.count == oldCount
    )
  }

  func reloadData() {
    orig.reloadData()
    let columnView = target.as(interface: SPTEqualizerColumnView.self)
    for label in columnView.labels {
      if label.gestureRecognizers == nil, let dataSource = columnView.dataSource {
        label.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(
          target: dataSource,
          action: #selector(
            target.as(interface: SPTEqualizerViewController.self).equalizerColumnLabelTapped(_:)))
        label.addGestureRecognizer(tapGesture)
        let longPressGesture = UILongPressGestureRecognizer(
          target: dataSource,
          action: #selector(
            target.as(interface: SPTEqualizerViewController.self).equalizerColumnLabelLongPressed(
              _:)))
        label.addGestureRecognizer(longPressGesture)
        label.backgroundColor = UIColor.black
        let encoreLabel = Dynamic.convert(label, to: SPTEncoreLabel.self)
        encoreLabel.numberOfLines = 2
        label.sizeToFit()
        encoreLabel.adjustsFontSizeToFitWidth = true
        encoreLabel.textAlignment = .center
      }
    }
  }

  func setValues(_ values: [Double]) {
    orig.setValues(values)
    target.as(interface: SPTEqualizerColumnView.self).reloadData()
  }
}
