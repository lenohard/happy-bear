from datetime import datetime, timezone, timedelta
import pytz


def main_original(date: str) -> dict:
    """原始实现"""
    from datetime import datetime, timezone, timedelta

    # 创建北京时区 (UTC+8)
    beijing_tz = timezone(timedelta(hours=8))

    # 解析日期字符串并添加北京时区信息
    dt_naive = datetime.fromisoformat(date)
    dt_beijing = dt_naive.replace(tzinfo=beijing_tz)

    # 转换为UTC时间戳（毫秒）
    timestamp_ms = int(dt_beijing.timestamp() * 1000)
    return {'result': timestamp_ms}


def main_corrected(date: str) -> dict:
    """修正后的实现"""
    from datetime import datetime, timedelta, timezone

    # 创建北京时区 (UTC+8)
    beijing_tz = timezone(timedelta(hours=8))

    # 解析日期字符串
    dt_naive = datetime.fromisoformat(date)

    # 正确方式：使用 localize 或 astimezone
    dt_beijing = dt_naive.replace(tzinfo=beijing_tz)

    # 转换为UTC时间戳（毫秒）
    timestamp_ms = int(dt_beijing.timestamp() * 1000)
    return {'result': timestamp_ms}


def main_with_pytz(date: str) -> dict:
    """使用 pytz 的正确实现"""
    # 解析日期字符串
    dt_naive = datetime.fromisoformat(date)

    # 使用 pytz 创建北京时间
    beijing_tz = pytz.timezone('Asia/Shanghai')
    dt_beijing = beijing_tz.localize(dt_naive)

    # 转换为UTC时间戳（毫秒）
    timestamp_ms = int(dt_beijing.timestamp() * 1000)
    return {'result': timestamp_ms}


def verify_timestamp(timestamp_ms: int):
    """验证时间戳"""
    timestamp_seconds = timestamp_ms / 1000

    # 转换为UTC时间
    utc_time = datetime.fromtimestamp(
        timestamp_seconds, tz=datetime.timezone.utc)

    # 转换为北京时间
    beijing_tz = pytz.timezone('Asia/Shanghai')
    beijing_time = utc_time.astimezone(beijing_tz)

    return {
        'utc': utc_time.strftime('%Y-%m-%d %H:%M:%S UTC'),
        'beijing': beijing_time.strftime('%Y-%m-%d %H:%M:%S CST')
    }


if __name__ == "__main__":
    # 测试不同的日期格式
    test_dates = [
        "2026-04-13",           # 只有日期
        "2026-04-13T00:00:00",  # 带时间
        "2026-04-13T12:30:45",  # 带具体时间
    ]

    print("=== 时间戳转换测试 ===\n")

    for date_str in test_dates:
        print(f"测试日期: {date_str}")
        print("-" * 40)

        try:
            # 原始实现
            result1 = main_original(date_str)
            ts1 = result1['result']
            verify1 = verify_timestamp(ts1)
            print(f"原始实现: {ts1}")
            print(f"  验证 - UTC: {verify1['utc']}")
            print(f"  验证 - 北京: {verify1['beijing']}")

            # pytz实现
            result2 = main_with_pytz(date_str)
            ts2 = result2['result']
            verify2 = verify_timestamp(ts2)
            print(f"pytz实现: {ts2}")
            print(f"  验证 - UTC: {verify2['utc']}")
            print(f"  验证 - 北京: {verify2['beijing']}")

            # 比较
            if ts1 == ts2:
                print("✅ 两种实现结果一致")
            else:
                print(f"❌ 结果不一致，差异: {ts2 - ts1} 毫秒")

        except Exception as e:
            print(f"❌ 错误: {e}")

        print("\n" + "="*50 + "\n")

    # 特别测试：检查时区处理是否正确
    print("=== 时区处理分析 ===")
    test_date = "2026-04-13T12:00:00"

    print(f"输入: {test_date}")
    dt_naive = datetime.fromisoformat(test_date)
    print(f"解析后的naive时间: {dt_naive}")

    # 原始方法
    beijing_tz_manual = timezone(timedelta(hours=8))
    dt_beijing_manual = dt_naive.replace(tzinfo=beijing_tz_manual)
    print(f"手动设置时区后: {dt_beijing_manual}")
    print(f"UTC时间: {dt_beijing_manual.astimezone(timezone.utc)}")

    # pytz方法
    beijing_tz_pytz = pytz.timezone('Asia/Shanghai')
    dt_beijing_pytz = beijing_tz_pytz.localize(dt_naive)
    print(f"pytz设置时区后: {dt_beijing_pytz}")
    print(f"UTC时间: {dt_beijing_pytz.astimezone(timezone.utc)}")
