//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import UIKit
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case today
	case games
	case sources
	case library
	case search
	case settings
	case certificates
	
	var title: String {
		switch self {
		case .today:        return "اليوم"
		case .games:        return "الألعاب"
		case .sources:     	return "التطبيقات"
		case .library: 		return "التوقيع"
		case .search:       return "بحث"
		case .settings: 	return "الإعدادات"
		case .certificates:	return "الشهادات"
		}
	}
	
	var icon: String {
		switch self {
		case .today:        return "doc.text.image"
		case .games:        return "paperplane.fill"
		case .sources: 		return "square.stack.3d.up.fill"
		case .library: 		return "arcade.stick"
		case .search:       return "magnifyingglass"
		case .settings: 	return "gearshape.fill"
		case .certificates: return "person.text.rectangle"
		}
	}
	
	@ViewBuilder
	var tabLabel: some View {
		switch self {
		case .games:
			Label {
				Text(title)
			} icon: {
				Image(uiImage: AppStoreCustomTabIcons.gamesRocketIcon)
			}
		case .library:
			Label {
				Text(title)
			} icon: {
				Image(uiImage: AppStoreCustomTabIcons.arcadeJoystickIcon)
			}
		default:
			Label(title, systemImage: icon)
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .today:        AppStoreTodayView()
		case .games:        AppStoreGamesView()
		case .sources:      SourcesView()
		case .library:      LibraryView()
		case .search:       AppStoreSearchView()
		case .settings:     SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.today,
			.games,
			.sources,
			.library,
			.search
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return []
	}
}

// MARK: - Exact App Store Custom Vector Icons (Rocket + Apple Arcade Isometric Joystick)
enum AppStoreCustomTabIcons {
	static let gamesRocketIcon: UIImage = {
		let size = CGSize(width: 26, height: 26)
		let renderer = UIGraphicsImageRenderer(size: size)
		let image = renderer.image { ctx in
			let cgContext = ctx.cgContext
			cgContext.translateBy(x: size.width / 2, y: size.height / 2)
			cgContext.rotate(by: .pi / 4)
			cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
			
			UIColor.white.setFill()
			
			let bodyPath = UIBezierPath()
			bodyPath.move(to: CGPoint(x: 13, y: 2.0))
			bodyPath.addCurve(
				to: CGPoint(x: 17.5, y: 14.5),
				controlPoint1: CGPoint(x: 16.8, y: 5.2),
				controlPoint2: CGPoint(x: 17.8, y: 10.2)
			)
			bodyPath.addLine(to: CGPoint(x: 16.0, y: 18.2))
			bodyPath.addLine(to: CGPoint(x: 10.0, y: 18.2))
			bodyPath.addLine(to: CGPoint(x: 8.5, y: 14.5))
			bodyPath.addCurve(
				to: CGPoint(x: 13, y: 2.0),
				controlPoint1: CGPoint(x: 8.2, y: 10.2),
				controlPoint2: CGPoint(x: 9.2, y: 5.2)
			)
			bodyPath.close()
			
			let leftFin = UIBezierPath()
			leftFin.move(to: CGPoint(x: 8.7, y: 12.8))
			leftFin.addCurve(
				to: CGPoint(x: 5.0, y: 18.8),
				controlPoint1: CGPoint(x: 6.2, y: 14.2),
				controlPoint2: CGPoint(x: 5.0, y: 16.5)
			)
			leftFin.addLine(to: CGPoint(x: 9.6, y: 17.5))
			leftFin.close()
			
			let rightFin = UIBezierPath()
			rightFin.move(to: CGPoint(x: 17.3, y: 12.8))
			rightFin.addCurve(
				to: CGPoint(x: 21.0, y: 18.8),
				controlPoint1: CGPoint(x: 19.8, y: 14.2),
				controlPoint2: CGPoint(x: 21.0, y: 16.5)
			)
			rightFin.addLine(to: CGPoint(x: 16.4, y: 17.5))
			rightFin.close()
			
			let flamePath = UIBezierPath()
			flamePath.move(to: CGPoint(x: 11.0, y: 19.4))
			flamePath.addQuadCurve(to: CGPoint(x: 13.0, y: 24.2), controlPoint: CGPoint(x: 11.2, y: 22.8))
			flamePath.addQuadCurve(to: CGPoint(x: 15.0, y: 19.4), controlPoint: CGPoint(x: 14.8, y: 22.8))
			flamePath.close()
			
			bodyPath.append(leftFin)
			bodyPath.append(rightFin)
			bodyPath.append(flamePath)
			bodyPath.fill()
			
			cgContext.setBlendMode(.clear)
			let windowRect = CGRect(x: 10.7, y: 8.2, width: 4.6, height: 4.6)
			UIBezierPath(ovalIn: windowRect).fill()
			cgContext.setBlendMode(.normal)
		}
		return image.withRenderingMode(.alwaysTemplate)
	}()
	
	// أيقونة عصا الأركيد الماسية ثلاثية الأبعاد المطابقة لأيقونة Apple Arcade
	static let arcadeJoystickIcon: UIImage = {
		let size = CGSize(width: 26, height: 26)
		let renderer = UIGraphicsImageRenderer(size: size)
		let image = renderer.image { ctx in
			let cg = ctx.cgContext
			UIColor.white.setFill()
			UIColor.white.setStroke()
			
			// 1. الكرة العلوية لعصا التحكم
			let ballRect = CGRect(x: 10.2, y: 2.2, width: 5.6, height: 5.6)
			UIBezierPath(ovalIn: ballRect).fill()
			
			// 2. العمود الأوسط لعصا التحكم
			let stickRect = CGRect(x: 12.0, y: 7.2, width: 2.0, height: 7.5)
			UIBezierPath(roundedRect: stickRect, cornerRadius: 1.0).fill()
			
			// 3. القاعدة الماسية العلوية (Isometric Diamond Deck)
			let topDeck = UIBezierPath()
			topDeck.move(to: CGPoint(x: 13.0, y: 11.2))
			topDeck.addLine(to: CGPoint(x: 23.2, y: 15.8))
			topDeck.addLine(to: CGPoint(x: 13.0, y: 20.4))
			topDeck.addLine(to: CGPoint(x: 2.8, y: 15.8))
			topDeck.close()
			topDeck.fill()
			
			// تفريغ فتحة صغيرة حول عمود العصا وزر جانبي لإبراز التفاصيل ثلاثية الأبعاد
			cg.setBlendMode(.clear)
			UIBezierPath(ovalIn: CGRect(x: 10.8, y: 13.6, width: 4.4, height: 2.4)).fill()
			UIBezierPath(ovalIn: CGRect(x: 6.8, y: 14.8, width: 2.0, height: 1.4)).fill()
			cg.setBlendMode(.normal)
			
			// إعادة رسم نهاية العصا وسط الفتحة
			UIBezierPath(roundedRect: CGRect(x: 12.0, y: 11.0, width: 2.0, height: 4.2), cornerRadius: 1.0).fill()
			
			// 4. الحافة السفلية ثلاثية الأبعاد للقاعدة الماسية
			let bottomLip = UIBezierPath()
			bottomLip.move(to: CGPoint(x: 3.2, y: 18.0))
			bottomLip.addLine(to: CGPoint(x: 13.0, y: 22.5))
			bottomLip.addLine(to: CGPoint(x: 22.8, y: 18.0))
			bottomLip.lineWidth = 2.0
			bottomLip.lineCapStyle = .round
			bottomLip.lineJoinStyle = .round
			bottomLip.stroke()
		}
		return image.withRenderingMode(.alwaysTemplate)
	}()
}
